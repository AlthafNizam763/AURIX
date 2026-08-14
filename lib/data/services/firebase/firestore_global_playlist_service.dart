import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import '../../models/playlist.dart';
import '../../models/playlist_key.dart';
import '../../models/song_key.dart';
import '../../models/track.dart';
import 'firestore_paths.dart';

/// The shared AURIX playlist catalogue, in Firestore.
///
/// ```
/// /playlists/{playlistId}
/// /playlists/{playlistId}/tracks/{trackId}
/// ```
///
/// ## What it is for
///
/// An imported playlist must not be private to the account that imported it.
/// User A imports "Love" and User B imports "Sad"; both playlists are then
/// findable, openable and playable by A, by B, and by every other signed-in
/// AURIX user. That is the whole requirement, and this collection is how it is
/// met — the same idea as `/catalog/songs`, one level up.
///
/// The account that imported a playlist is *recorded* on the document —
/// `importedByUserId`, `importedBy`, `importedAt` — and that record narrows
/// nothing. No read here filters by uid. A query that did would put the
/// architecture back where it started, so there is exactly one place a uid
/// appears in this file ([watchImportedBy], which answers "what have *I*
/// contributed?" for the Library screen) and it is not on any discovery path.
///
/// ## De-duplication is structural
///
/// Document ids come from [PlaylistKey], derived from (`source`, `sourceId`).
/// The same Spotify playlist imported by two accounts on two days addresses one
/// document, so there is no read-then-write window to lose: the id *is* the
/// check. [findBySource] exists for the import path's "you already have this"
/// prompt, not to make the write safe.
///
/// ## What the rules can and cannot do about it
///
/// Stated plainly, because this is a collection every user can write to and
/// every user reads. `firestore.rules` enforces *shape*: a create must carry
/// exactly the fields this service writes, each bounded; an update may touch
/// only the fields a re-sync legitimately improves, and never the provenance or
/// the source identity; a delete is refused to everybody but the importer. It
/// cannot enforce *truth* — a client can still write a well-formed playlist
/// whose cover art does not match its title. Closing that needs the write to
/// happen where the client cannot reach, and the swap is one Cloud Function and
/// one rules block. `PlaylistCatalogRepository` is the seam, and its comment is
/// the map.
class FirestoreGlobalPlaylistService {
  FirestoreGlobalPlaylistService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// The gap left between adjacent tracks. Matches the personal playlist
  /// service — see its class comment for why `position` is a double.
  static const double _positionGap = 1024;

  /// Firestore's cap on operations in one batch.
  static const int _batchLimit = 500;

  /// How much extra to read when a query has words the index cannot match.
  /// Same reasoning as `FirestoreCatalogService._searchFanout`.
  static const int _searchFanout = 4;

  // -------------------------------------------------------------------------
  // Discovery
  // -------------------------------------------------------------------------

  /// Playlists whose title matches [query], from the whole catalogue.
  ///
  /// ## Case, partial words, and why this is not a `contains`
  ///
  /// "love", "Love" and "LOVE" all find "Love Songs", and so does "lov". Both
  /// properties come from the token array rather than from anything done at
  /// query time: [SearchTokens.forPlaylist] normalises the title to lower case
  /// and expands each word to its prefixes at *write* time, so a keystroke is
  /// one indexed `array-contains` and never a scan. A client-side
  /// `title.contains(query)` would have to read the collection to answer, which
  /// is precisely what must not happen once the catalogue is large — the cost
  /// of a search here is bounded by [limit] no matter how many playlists exist.
  ///
  /// Firestore permits one `array-contains` per query, so a multi-word query is
  /// matched on its most selective word and the rest are applied in memory over
  /// the returned page. That is a real limitation, shared with the song
  /// catalogue, and [_searchFanout] is the cheap mitigation.
  ///
  /// Never throws. Search is a page assembled from several providers, and one
  /// of them failing must not empty the page.
  Future<List<Playlist>> search(String query, {int limit = 20}) async {
    final token = SearchTokens.queryToken(query);
    if (token.isEmpty) return const <Playlist>[];

    AppLogger.info('Searching global playlists: $query', scope: 'search');

    final residual = SearchTokens.residualWords(query);

    try {
      final snapshot = await FirestorePaths.globalPlaylists(_db)
          // No uid filter, deliberately and permanently. Every signed-in
          // account searches the same catalogue and sees the same playlists.
          .where(FirestoreFields.searchTokens, arrayContains: token)
          .limit(residual.isEmpty ? limit : limit * _searchFanout)
          .get();

      final matches = <Playlist>[];
      for (final doc in snapshot.docs) {
        final playlist = _playlistFrom(doc.id, doc.data());
        if (playlist == null) continue;
        if (!_matchesResidual(doc.data(), playlist, residual)) continue;
        matches.add(playlist);
      }

      _rankByRelevance(matches, query);
      final results = matches.take(limit).toList(growable: false);

      AppLogger.info('Results: ${results.length}', scope: 'search');
      return results;
    } on Object catch (error) {
      AppLogger.warn(
        'Global playlist search failed for "$query"',
        scope: 'search',
        error: error,
      );
      return const <Playlist>[];
    }
  }

  /// One shared playlist, live.
  ///
  /// No uid anywhere: this is what lets User B open a playlist User A imported.
  Stream<Playlist?> watch(String playlistId) =>
      FirestorePaths.globalPlaylist(_db, playlistId).snapshots().map((snapshot) {
        final data = snapshot.data();
        if (!snapshot.exists || data == null) return null;
        return _playlistFrom(snapshot.id, data);
      });

  Future<Playlist?> read(String playlistId) async {
    final snapshot = await FirestorePaths.globalPlaylist(_db, playlistId).get();
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return _playlistFrom(snapshot.id, data);
  }

  /// A shared playlist's tracks, in playlist order.
  ///
  /// One copy, read by everybody who opens the playlist. The tracks are not
  /// duplicated into each user's library — that is the point of them hanging
  /// off the shared document.
  Stream<List<Track>> watchTracks(String playlistId) =>
      FirestorePaths.globalPlaylistTracks(_db, playlistId)
          .orderBy(FirestoreFields.position)
          .snapshots()
          .map(_tracksFrom)
          .handleError((Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Shared playlist track stream failed for $playlistId',
              scope: 'playlists',
              error: error,
              stackTrace: stackTrace,
            );
          });

  Future<List<Track>> readTracks(String playlistId) async {
    final snapshot = await FirestorePaths.globalPlaylistTracks(_db, playlistId)
        .orderBy(FirestoreFields.position)
        .get();
    return _tracksFrom(snapshot);
  }

  /// What this account has contributed to the catalogue.
  ///
  /// The one query in this file that mentions a uid, and it is not a discovery
  /// path: the Library screen shows a user their own imports alongside the
  /// playlists they built here. Discovery — [search], [watch], [watchTracks] —
  /// never filters by account.
  Stream<List<Playlist>> watchImportedBy(String uid) =>
      FirestorePaths.globalPlaylists(_db)
          .where(FirestoreFields.importedByUserId, isEqualTo: uid)
          .snapshots()
          .map((snapshot) {
            final out = <Playlist>[];
            for (final doc in snapshot.docs) {
              final playlist = _playlistFrom(doc.id, doc.data());
              if (playlist != null) out.add(playlist);
            }
            // Sorted here rather than by Firestore. `where` + `orderBy` on two
            // different fields needs a composite index, and this list is one
            // user's imports — small enough that ordering it costs nothing.
            out.sort((a, b) {
              final left = b.updatedAt ?? b.importedAt;
              final right = a.updatedAt ?? a.importedAt;
              if (left == null && right == null) return 0;
              if (left == null) return 1;
              if (right == null) return -1;
              return left.compareTo(right);
            });
            return out;
          })
          .handleError((Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Imported playlist stream failed',
              scope: 'playlists',
              error: error,
              stackTrace: stackTrace,
            );
          });

  /// Finds a playlist already in the catalogue by its identity at the source.
  ///
  /// **Global by construction.** There is no uid parameter and no `ownerId`
  /// clause, so `spotify + 37i9dQZF1DX3lmpQSniUBH` resolves to the same
  /// document whichever account asks — which is what makes User B's import of a
  /// playlist User A already brought in an update rather than a duplicate.
  ///
  /// One document read in the normal case, because [PlaylistKey] makes the id a
  /// function of the pair. The query is a fallback for a document written by a
  /// build with a different id scheme; it costs a read only when the direct
  /// lookup misses, and it is what keeps (`source`, `sourceId`) the real
  /// uniqueness rule rather than the id shape.
  Future<Playlist?> findBySource({
    required MediaSource source,
    required String sourceId,
  }) async {
    if (sourceId.trim().isEmpty) return null;

    final id = PlaylistKey.of(source: source, sourceId: sourceId);
    final direct = await read(id);
    if (direct != null) return direct;

    try {
      final snapshot = await FirestorePaths.globalPlaylists(_db)
          .where(FirestoreFields.source, isEqualTo: source.wireValue)
          .where(FirestoreFields.sourceId, isEqualTo: sourceId)
          .limit(1)
          .get();
      if (snapshot.docs.isEmpty) return null;
      final doc = snapshot.docs.first;
      return _playlistFrom(doc.id, doc.data());
    } on Object catch (error) {
      // A failed fallback means "not found", which is the safe answer: the
      // import proceeds and its write lands on the deterministic id, merging
      // with anything already there rather than duplicating it.
      AppLogger.warn(
        'Catalogue lookup by source failed',
        scope: 'import',
        error: error,
      );
      return null;
    }
  }

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  /// Creates the catalogue entry for an imported playlist, or refreshes the one
  /// already there. Returns the document id.
  ///
  /// Idempotent, and that is the requirement it exists to meet: importing the
  /// same source playlist twice — by the same account or by two different ones
  /// — writes one document.
  ///
  /// Provenance is written **only on create**. A re-sync run by another account
  /// must not rewrite `importedByUserId` and steal the credit (nor the delete
  /// right that hangs off it), and `importedAt` records when the playlist
  /// entered the catalogue, not when it was last touched. The security rules
  /// enforce the same thing from the other side.
  Future<String> upsert({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) async {
    final id = PlaylistKey.of(source: source, sourceId: sourceId);
    final reference = FirestorePaths.globalPlaylist(_db, id);
    final existing = await reference.get();
    final trimmedName = name.trim();

    if (existing.exists) {
      AppLogger.info('Existing global playlist found: $id', scope: 'import');

      // Reached when two accounts import the same source playlist at once: the
      // duplicate check said "new", and by the time the write lands somebody
      // else has created the document. The loser of that race is not the
      // importer, and the `/playlists` update rule allows them only
      // `trackCount`, `syncedAt` and `updatedAt` — so sending the metadata
      // anyway would fail the whole write with permission-denied rather than
      // being trimmed to what is permitted.
      final isImporter =
          existing.data()?[FirestoreFields.importedByUserId] ==
              importedByUserId;

      await reference.update(<String, Object?>{
        if (isImporter) ...<String, Object?>{
          if (trimmedName.isNotEmpty) ...<String, Object?>{
            FirestoreFields.name: trimmedName,
            FirestoreFields.searchTitle: SongKey.normaliseAlbum(trimmedName),
            // Re-tokenised with the name, never separately. A refresh that left
            // the tokens behind would make the playlist findable only by its
            // old title — the kind of bug nobody notices until a user reports
            // it.
            FirestoreFields.searchTokens: SearchTokens.forPlaylist(trimmedName),
          },
          // The description is deliberately not touched. See markSynced.
          if (coverUrl.isNotEmpty) 'coverUrl': coverUrl,
          if (sourceUrl != null && sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
        },
        FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
      });
      return id;
    }

    AppLogger.info('Creating global playlist: $id', scope: 'import');
    await reference.set(<String, Object?>{
      FirestoreFields.name: trimmedName,
      'description': description.trim(),
      'coverUrl': coverUrl,
      FirestoreFields.source: source.wireValue,
      FirestoreFields.sourceId: sourceId,
      FirestoreFields.sourceUrl: sourceUrl ?? '',
      FirestoreFields.searchTitle: SongKey.normaliseAlbum(trimmedName),
      FirestoreFields.searchTokens: SearchTokens.forPlaylist(trimmedName),
      FirestoreFields.trackCount: 0,
      // Provenance. Recorded once, never narrowing a read.
      FirestoreFields.importedByUserId: importedByUserId,
      FirestoreFields.importedBy: (importedBy ?? '').trim(),
      FirestoreFields.importedAt: FieldValue.serverTimestamp(),
      FirestoreFields.createdAt: FieldValue.serverTimestamp(),
      FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
    });
    return id;
  }

  /// Writes [tracks] into a shared playlist in exactly the given order.
  ///
  /// The same contract as the personal service's `writeTracksInOrder`: rows are
  /// merged so a re-import improves metadata without resetting `position`, and
  /// duplicates within one source playlist are collapsed before the batch is
  /// built, because two `set` operations on one document id in a single batch
  /// are rejected outright.
  Future<int> writeTracksInOrder({
    required String playlistId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return 0;

    final collection = FirestorePaths.globalPlaylistTracks(_db, playlistId);
    var written = 0;
    final seen = <String>{};

    final ordered = <Track>[];
    for (final track in tracks) {
      if (seen.add(track.documentId)) ordered.add(track);
    }

    for (var start = 0; start < ordered.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, ordered.length);
      final batch = _db.batch();

      for (var i = start; i < end; i++) {
        final track = ordered[i];
        batch.set(
          collection.doc(track.documentId),
          <String, Object?>{
            ...track.toFirestore(),
            FirestoreFields.position: (i + 1) * _positionGap,
            FirestoreFields.createdAt: FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
        written++;
      }

      await batch.commit();
    }

    await _syncTrackCount(playlistId);
    return written;
  }

  /// Removes rows the source no longer lists.
  ///
  /// Callable only by the importer — the rules refuse a shared-track delete to
  /// anyone else, because a track removed here is removed for every user who
  /// opens the playlist. `PlaylistImportService` checks before calling rather
  /// than letting the write fail, so a re-sync run by a different account
  /// refreshes what it can instead of erroring.
  Future<int> removeTracks({
    required String playlistId,
    required List<String> trackIds,
  }) async {
    if (trackIds.isEmpty) return 0;

    final collection = FirestorePaths.globalPlaylistTracks(_db, playlistId);
    var removed = 0;

    for (var start = 0; start < trackIds.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, trackIds.length);
      final batch = _db.batch();
      for (var i = start; i < end; i++) {
        batch.delete(collection.doc(trackIds[i]));
        removed++;
      }
      await batch.commit();
    }

    await _syncTrackCount(playlistId);
    return removed;
  }

  /// Records the outcome of a re-sync against the playlist's source.
  ///
  /// Refreshes the source-side name and cover and stamps `syncedAt`. The
  /// description is deliberately **not** touched: a user may have edited it,
  /// and overwriting an edit with a stale line from the source is worse than
  /// leaving the line stale.
  Future<void> markSynced({
    required String playlistId,
    String? name,
    String? coverUrl,
  }) => FirestorePaths.globalPlaylist(_db, playlistId).update(<String, Object?>{
    if (name != null && name.trim().isNotEmpty) ...<String, Object?>{
      FirestoreFields.name: name.trim(),
      FirestoreFields.searchTitle: SongKey.normaliseAlbum(name.trim()),
      FirestoreFields.searchTokens: SearchTokens.forPlaylist(name),
    },
    if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
    FirestoreFields.syncedAt: FieldValue.serverTimestamp(),
    FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
  });

  /// Removes a playlist from the catalogue, and everything in it.
  ///
  /// Refused by the rules to everyone but the importer. Firestore does not
  /// delete subcollections with their parent, so the rows go first — otherwise
  /// they survive as orphans, invisible, billed, and ready to reappear in full
  /// if a playlist were ever created with the same id, which [PlaylistKey]
  /// makes likely rather than hypothetical.
  Future<void> delete(String playlistId) async {
    final tracks = FirestorePaths.globalPlaylistTracks(_db, playlistId);

    while (true) {
      final page = await tracks.limit(_batchLimit).get();
      if (page.docs.isEmpty) break;

      final batch = _db.batch();
      for (final doc in page.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (page.docs.length < _batchLimit) break;
    }

    await FirestorePaths.globalPlaylist(_db, playlistId).delete();
    AppLogger.info('Deleted global playlist $playlistId', scope: 'playlists');
  }

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  /// Recomputes `trackCount` from the subcollection.
  ///
  /// An aggregate `count()`, billed as one read rather than one per document.
  /// Recounted rather than incremented because the writes above merge: an
  /// increment would drift upward on every re-sync until the count no longer
  /// matched the list.
  Future<void> _syncTrackCount(String playlistId) async {
    try {
      final count = await FirestorePaths.globalPlaylistTracks(_db, playlistId)
          .count()
          .get();
      await FirestorePaths.globalPlaylist(_db, playlistId).update(
        <String, Object?>{
          FirestoreFields.trackCount: count.count ?? 0,
          FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
        },
      );
    } on Object catch (error) {
      // A wrong count is a cosmetic subtitle, not a broken playlist. The rows
      // are already written and the next sync corrects it.
      AppLogger.warn(
        'Could not sync track count for $playlistId',
        scope: 'playlists',
        error: error,
      );
    }
  }

  Playlist? _playlistFrom(String id, Map<String, dynamic> data) {
    try {
      return Playlist.fromFirestore(id, data, visibility: PlaylistVisibility.shared);
    } on Object catch (error) {
      AppLogger.warn(
        'Skipping unreadable shared playlist $id',
        scope: 'playlists',
        error: error,
      );
      return null;
    }
  }

  /// The words a result must contain beyond the one the index matched.
  ///
  /// Applied over the page the index returned, never over the collection.
  static bool _matchesResidual(
    Map<String, dynamic> data,
    Playlist playlist,
    List<String> words,
  ) {
    if (words.isEmpty) return true;
    final stored = data[FirestoreFields.searchTitle];
    final haystack = stored is String && stored.isNotEmpty
        ? stored
        : SongKey.normaliseAlbum(playlist.name);
    return words.every(haystack.contains);
  }

  /// Orders a result page so the closest title comes first.
  ///
  /// An exact title match outranks a title that merely starts with the query,
  /// which outranks one that only contains it; ties break on how many songs the
  /// playlist has, because a fuller playlist is the more useful answer. All of
  /// it is over the bounded page the index already returned — no extra reads.
  static void _rankByRelevance(List<Playlist> playlists, String query) {
    final needle = SongKey.normaliseAlbum(query);
    if (needle.isEmpty) return;

    int score(Playlist playlist) {
      final title = SongKey.normaliseAlbum(playlist.name);
      if (title == needle) return 0;
      if (title.startsWith(needle)) return 1;
      if (title.contains(needle)) return 2;
      return 3;
    }

    playlists.sort((a, b) {
      final byScore = score(a).compareTo(score(b));
      if (byScore != 0) return byScore;
      final byCount = b.trackCount.compareTo(a.trackCount);
      if (byCount != 0) return byCount;
      // Document id last, so two equally good answers come back in the same
      // order on every device rather than in whatever order Firestore paged.
      return a.id.compareTo(b.id);
    });
  }

  List<Track> _tracksFrom(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final rows = <({Track track, double position})>[];
    for (final doc in snapshot.docs) {
      try {
        final data = doc.data();
        final position = data[FirestoreFields.position];
        rows.add((
          track: Track.fromFirestore(doc.id, data),
          position: position is num ? position.toDouble() : 0,
        ));
      } on Object catch (error) {
        AppLogger.warn(
          'Skipping unreadable shared track ${doc.id}',
          scope: 'playlists',
          error: error,
        );
      }
    }

    rows.sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      if (byPosition != 0) return byPosition;
      return a.track.id.compareTo(b.track.id);
    });

    return rows.map((row) => row.track).toList(growable: false);
  }
}
