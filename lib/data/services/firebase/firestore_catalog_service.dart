import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/utils/app_logger.dart';
import '../../models/song.dart';
import '../../models/song_key.dart';
import 'firestore_paths.dart';

/// The shared AURIX song catalogue, in Firestore.
///
/// ```
/// /catalog/songs/{songId}
/// ```
///
/// ## What it is for
///
/// An imported song must not exist only inside the playlist it arrived in. If
/// it did, searching for "Blinding Lights" would find nothing unless the user
/// happened to be inside the playlist that holds it — which is the behaviour
/// this collection exists to prevent. Every import writes here, and global
/// search reads here.
///
/// ## De-duplication
///
/// The document id is derived from the song, not allocated — see [SongKey]. So
/// the same song imported from two playlists, by two users, or from two
/// different services all address one document. There is no "check then write"
/// race to lose, because the id *is* the check.
///
/// Cross-service matching falls out of the same property: the key is built from
/// a normalised title and primary artist rather than from a provider id, so the
/// Spotify and YouTube copies of one song converge and the surviving document
/// carries both provider ids.
///
/// ## Why writes merge rather than replace
///
/// A second import of a song that is already catalogued must be able to improve
/// the row — supply an album name the first source lacked, a duration, the
/// other service's id — without erasing what is there or resetting when it was
/// first seen. [Song.toFirestoreMerge] computes exactly the fields worth
/// changing, and a write with nothing to change is skipped entirely rather than
/// billed.
class FirestoreCatalogService {
  FirestoreCatalogService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// Firestore's cap on operations in one batch.
  static const int _batchLimit = 500;

  /// Firestore's cap on values in an `in` / `whereIn` query.
  static const int _lookupChunk = 30;

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  Future<Song?> song(String songId) async {
    final snapshot = await FirestorePaths.catalogSong(_db, songId).get();
    final data = snapshot.data();
    if (!snapshot.exists || data == null) return null;
    return Song.fromFirestore(snapshot.id, data);
  }

  /// Reads many catalogue songs by id.
  ///
  /// Chunked at Firestore's `whereIn` limit. Used by the import path to find
  /// out which of the songs it is about to write already exist, so that the
  /// ones that do can be merged rather than overwritten — which is what stops a
  /// re-import from erasing a field an earlier import contributed.
  Future<Map<String, Song>> songsByIds(List<String> ids) async {
    final found = <String, Song>{};
    if (ids.isEmpty) return found;

    final unique = ids.toSet().toList(growable: false);

    for (var start = 0; start < unique.length; start += _lookupChunk) {
      final end = (start + _lookupChunk).clamp(0, unique.length);
      final chunk = unique.sublist(start, end);

      try {
        final snapshot = await FirestorePaths.catalogSongs(_db)
            .where(FieldPath.documentId, whereIn: chunk)
            .get();

        for (final doc in snapshot.docs) {
          found[doc.id] = Song.fromFirestore(doc.id, doc.data());
        }
      } on Object catch (error) {
        // A failed existence check is not a failed import: the write path
        // treats an unknown song as new, which merges rather than replaces
        // anyway. Logged so a rules problem is visible rather than silent.
        AppLogger.warn(
          'Catalogue lookup failed for ${chunk.length} ids',
          scope: 'catalog',
          error: error,
        );
      }
    }

    return found;
  }

  // -------------------------------------------------------------------------
  // Search
  // -------------------------------------------------------------------------

  /// Songs matching [query], as an indexed lookup rather than a scan.
  ///
  /// One `array-contains` on the precomputed token array, bounded by [limit].
  /// A keystroke therefore costs at most [limit] document reads no matter how
  /// large the catalogue grows — which is the requirement this design exists to
  /// meet. There is no path here that reads the collection.
  ///
  /// Firestore permits only one `array-contains` per query, so a multi-word
  /// query is matched on its most selective word and the remaining words are
  /// applied in memory over the returned page. That is a genuine limitation and
  /// worth naming: a query whose *other* words are the selective ones can
  /// return fewer results than a full-text engine would. Over-fetching a little
  /// ([_searchFanout]) is the cheap mitigation.
  Future<List<Song>> search(String query, {int limit = 20}) async {
    final token = SearchTokens.queryToken(query);
    if (token.isEmpty) return const <Song>[];

    final residual = SearchTokens.residualWords(query);

    try {
      final snapshot = await FirestorePaths.catalogSongs(_db)
          .where(FirestoreFields.searchTokens, arrayContains: token)
          .limit(residual.isEmpty ? limit : limit * _searchFanout)
          .get();

      final songs = <Song>[];
      for (final doc in snapshot.docs) {
        final song = Song.fromFirestore(doc.id, doc.data());
        if (!_matchesResidual(song, residual)) continue;
        songs.add(song);
        if (songs.length >= limit) break;
      }

      return songs;
    } on Object catch (error) {
      AppLogger.warn(
        'Catalogue search failed for "$query"',
        scope: 'catalog',
        error: error,
      );
      return const <Song>[];
    }
  }

  /// How much extra to read when a query has words the index cannot match.
  ///
  /// Four is a guess with a rationale rather than a tuned number: it keeps the
  /// worst-case read for a two-word query at eighty documents, which is still
  /// bounded and still cheap, while making it unlikely that every one of the
  /// first twenty hits is filtered out in memory.
  static const int _searchFanout = 4;

  static bool _matchesResidual(Song song, List<String> words) {
    if (words.isEmpty) return true;
    final haystack = SongKey.normaliseAlbum(
      '${song.title} ${song.artistNames} ${song.album}',
    );
    return words.every(haystack.contains);
  }

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  /// Writes [songs] into the catalogue, creating or improving each.
  ///
  /// Returns the number of documents actually written — new plus genuinely
  /// updated — which is smaller than `songs.length` whenever an import
  /// re-encounters songs the catalogue already had in full.
  ///
  /// The existence check is one batched read up front rather than a read per
  /// song, and songs with nothing to improve are dropped before the batch is
  /// built, so a re-import of an unchanged 200-track playlist costs a handful
  /// of reads and **zero** writes.
  Future<int> upsertAll(List<Song> songs) async {
    if (songs.isEmpty) return 0;

    // De-duplicated first: the same song twice in one playlist would otherwise
    // be two operations on one document id inside a single batch, which
    // Firestore rejects outright.
    final byId = <String, Song>{};
    for (final song in songs) {
      final existing = byId[song.id];
      byId[song.id] = existing == null ? song : _preferRicher(existing, song);
    }

    final existing = await songsByIds(byId.keys.toList(growable: false));

    final creates = <Song>[];
    final updates = <String, Map<String, dynamic>>{};

    for (final song in byId.values) {
      final current = existing[song.id];
      if (current == null) {
        creates.add(song);
        continue;
      }

      final delta = song.toFirestoreMerge(current);
      // An empty delta means the catalogue already knows everything this copy
      // could contribute. Writing it anyway would bill a write and bump
      // `updatedAt` for no change at all.
      if (delta.isNotEmpty) updates[song.id] = delta;
    }

    var written = 0;
    written += await _commitCreates(creates);
    written += await _commitUpdates(updates);

    AppLogger.info(
      'Catalogue: ${creates.length} new, ${updates.length} improved, '
      '${byId.length - creates.length - updates.length} unchanged',
      scope: 'catalog',
    );

    return written;
  }

  /// Of two descriptions of one song, the one carrying more.
  ///
  /// Reached when a single playlist lists the same song twice — genuinely
  /// common in long compilations — and the two entries differ in completeness.
  static Song _preferRicher(Song a, Song b) {
    int score(Song song) =>
        (song.album.isNotEmpty ? 1 : 0) +
        (song.durationMs > 0 ? 1 : 0) +
        ((song.artworkUrl?.isNotEmpty ?? false) ? 1 : 0);
    return score(b) > score(a) ? b : a;
  }

  Future<int> _commitCreates(List<Song> songs) async {
    var written = 0;

    for (var start = 0; start < songs.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, songs.length);
      final batch = _db.batch();

      for (var i = start; i < end; i++) {
        final song = songs[i];
        batch.set(FirestorePaths.catalogSong(_db, song.id), <String, dynamic>{
          ...song.toFirestore(),
          // Server timestamps: a shared collection cannot be ordered by a
          // client clock, and one device with a wrong date would otherwise
          // reorder the catalogue for everybody.
          FirestoreFields.createdAt: FieldValue.serverTimestamp(),
          FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
        });
        written++;
      }

      await batch.commit();
    }

    return written;
  }

  Future<int> _commitUpdates(Map<String, Map<String, dynamic>> updates) async {
    if (updates.isEmpty) return 0;

    var written = 0;
    final entries = updates.entries.toList(growable: false);

    for (var start = 0; start < entries.length; start += _batchLimit) {
      final end = (start + _batchLimit).clamp(0, entries.length);
      final batch = _db.batch();

      for (var i = start; i < end; i++) {
        final entry = entries[i];
        batch.set(
          FirestorePaths.catalogSong(_db, entry.key),
          <String, dynamic>{
            ...entry.value,
            FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
          },
          // Merge, not replace. The delta holds only the fields worth
          // changing; a plain `set` would delete every field absent from it.
          SetOptions(merge: true),
        );
        written++;
      }

      await batch.commit();
    }

    return written;
  }
}
