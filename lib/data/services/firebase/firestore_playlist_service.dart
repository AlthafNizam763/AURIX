import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'firestore_paths.dart';

/// AURIX's own playlists, in Firestore.
///
/// ```
/// /users/{uid}/playlists/{playlistId}
/// /users/{uid}/playlists/{playlistId}/tracks/{trackId}
/// ```
///
/// ## Ordering: why `position` is a double
///
/// A playlist is an ordered list, and Firestore collections are not. The order
/// is therefore a field, and the choice of *what* field decides how expensive a
/// reorder is.
///
/// Integer indices are the obvious choice and the wrong one: moving one track
/// from position 40 to position 2 renumbers 38 documents, which is 38 writes
/// billed and 38 documents that a listener on another device sees change. Doing
/// that on every drag of a drag-to-reorder gesture is not viable.
///
/// So `position` is a fractional rank. To place a track between two others,
/// give it the midpoint of their positions — one write, no matter how long the
/// playlist. New tracks are appended at `last + 1024`, leaving room to insert
/// above them without touching anything.
///
/// The failure mode of fractional ranking is worth stating because it is
/// bounded and handled: repeatedly inserting between the same two neighbours
/// halves the gap each time, and after about fifty such inserts the two doubles
/// are adjacent and no midpoint exists. [_needsRebalance] detects that and
/// [_rebalance] renumbers the playlist once — the expensive operation, paid
/// approximately never instead of on every reorder.
class FirestorePlaylistService {
  FirestorePlaylistService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// The gap left between adjacent tracks. Large enough that fifty inserts
  /// between the same pair still find a midpoint.
  static const double _positionGap = 1024;

  /// Below this, two positions are too close to reliably find a midpoint.
  static const double _minimumGap = 0.0001;

  /// Firestore's cap on operations in one batch.
  static const int _batchLimit = 500;

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  /// Every playlist the user owns, newest edit first.
  ///
  /// Ordered by `updatedAt` rather than by name: a library screen is a list of
  /// things you are working with, and the one you touched last is the one you
  /// are most likely to want. The screen re-sorts locally when the user asks
  /// for something else, which costs nothing on a list this size and avoids a
  /// composite index per sort order.
  Stream<List<Playlist>> watchPlaylists(String uid) =>
      FirestorePaths.playlistsOf(_db, uid)
          .orderBy(FirestoreFields.updatedAt, descending: true)
          .snapshots()
          .map(_playlistsFrom)
          .handleError((Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Playlist stream failed',
              scope: 'playlists',
              error: error,
              stackTrace: stackTrace,
            );
          });

  Stream<Playlist?> watchPlaylist(String uid, String playlistId) =>
      FirestorePaths.playlist(_db, uid, playlistId).snapshots().map((snapshot) {
        final data = snapshot.data();
        if (!snapshot.exists || data == null) return null;
        return Playlist.fromFirestore(snapshot.id, data);
      });

  /// A playlist's tracks, in playlist order.
  Stream<List<Track>> watchTracks(String uid, String playlistId) =>
      FirestorePaths.playlistTracks(_db, uid, playlistId)
          .orderBy(FirestoreFields.position)
          .snapshots()
          .map(_tracksFrom)
          .handleError((Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Playlist track stream failed for $playlistId',
              scope: 'playlists',
              error: error,
              stackTrace: stackTrace,
            );
          });

  Future<List<Track>> readTracks(String uid, String playlistId) async {
    final snapshot = await FirestorePaths.playlistTracks(_db, uid, playlistId)
        .orderBy(FirestoreFields.position)
        .get();
    return _tracksFrom(snapshot);
  }

  Future<List<Playlist>> readPlaylists(String uid) async {
    final snapshot = await FirestorePaths.playlistsOf(_db, uid)
        .orderBy(FirestoreFields.updatedAt, descending: true)
        .get();
    return _playlistsFrom(snapshot);
  }

  /// Finds an already-imported playlist by its id at the source.
  ///
  /// What makes re-importing update rather than duplicate. Returns null when
  /// this playlist has not been imported before.
  Future<Playlist?> findBySource(
    String uid, {
    required MediaSource source,
    required String sourceId,
  }) async {
    final snapshot = await FirestorePaths.playlistsOf(_db, uid)
        .where(FirestoreFields.source, isEqualTo: source.wireValue)
        .where(FirestoreFields.sourceId, isEqualTo: sourceId)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return null;
    final doc = snapshot.docs.first;
    return Playlist.fromFirestore(doc.id, doc.data());
  }

  // -------------------------------------------------------------------------
  // Playlist lifecycle
  // -------------------------------------------------------------------------

  /// Creates a playlist and returns its id.
  Future<String> create({
    required String uid,
    required String name,
    String description = '',
    String coverUrl = '',
    MediaSource source = MediaSource.aurix,
    String? sourceId,
  }) async {
    final reference = FirestorePaths.playlistsOf(_db, uid).doc();
    await reference.set(<String, Object?>{
      'name': name.trim(),
      'description': description.trim(),
      'coverUrl': coverUrl,
      'source': source.wireValue,
      'sourceId': sourceId,
      FirestoreFields.trackCount: 0,
      FirestoreFields.createdAt: FieldValue.serverTimestamp(),
      FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
    });
    AppLogger.info('Created playlist ${reference.id}', scope: 'playlists');
    return reference.id;
  }

  Future<void> rename({
    required String uid,
    required String playlistId,
    required String name,
    String? description,
  }) => FirestorePaths.playlist(_db, uid, playlistId).update(<String, Object?>{
    'name': name.trim(),
    if (description != null) 'description': description.trim(),
    FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
  });

  Future<void> setCover({
    required String uid,
    required String playlistId,
    required String coverUrl,
  }) => FirestorePaths.playlist(_db, uid, playlistId).update(<String, Object?>{
    'coverUrl': coverUrl,
    FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
  });

  /// Deletes a playlist and everything in it.
  ///
  /// Firestore does **not** delete subcollections when a document is deleted —
  /// the tracks would survive as orphans, invisible in the UI, counting against
  /// storage, and reappearing in full if a playlist were ever created with the
  /// same id. So the rows are deleted explicitly first.
  ///
  /// Batched at Firestore's limit rather than one write per track: a
  /// 2,000-track playlist is four round trips this way and 2,000 otherwise.
  Future<void> delete({required String uid, required String playlistId}) async {
    final tracks = FirestorePaths.playlistTracks(_db, uid, playlistId);

    while (true) {
      final page = await tracks.limit(_batchLimit).get();
      if (page.docs.isEmpty) break;

      final batch = _db.batch();
      for (final doc in page.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      // A page shorter than the limit was the last one.
      if (page.docs.length < _batchLimit) break;
    }

    await FirestorePaths.playlist(_db, uid, playlistId).delete();
    AppLogger.info('Deleted playlist $playlistId', scope: 'playlists');
  }

  // -------------------------------------------------------------------------
  // Membership
  // -------------------------------------------------------------------------

  /// Appends [track] to a playlist.
  ///
  /// A transaction, because the write touches two documents that must agree:
  /// the new track row and the parent's `trackCount`. Without it, two devices
  /// adding at once would both read a count of 9 and both write 10.
  ///
  /// Adding a track that is already in the playlist is a no-op rather than a
  /// duplicate row — the document id is derived from the track, so the second
  /// add addresses the same document. That is the behaviour the UI wants
  /// ("Add to playlist" from two screens should not double it) and it is also
  /// why [Track.documentId] has to be deterministic.
  Future<void> addTrack({
    required String uid,
    required String playlistId,
    required Track track,
  }) async {
    final playlist = FirestorePaths.playlist(_db, uid, playlistId);
    final trackId = track.documentId;
    final row = FirestorePaths.playlistTracks(_db, uid, playlistId).doc(trackId);

    // Read outside the transaction: `orderBy().limit()` is a query, and
    // Firestore transactions can only read documents, not run queries.
    // The consequence is a benign race — two simultaneous appends can land on
    // the same position — and the tie is broken deterministically by the
    // secondary sort in `_tracksFrom`.
    final last = await _lastPosition(uid, playlistId);

    await _db.runTransaction((transaction) async {
      final existing = await transaction.get(row);
      if (existing.exists) return;

      transaction.set(row, <String, Object?>{
        ...track.toFirestore(),
        FirestoreFields.position: last + _positionGap,
        FirestoreFields.createdAt: FieldValue.serverTimestamp(),
      });
      transaction.update(playlist, <String, Object?>{
        FirestoreFields.trackCount: FieldValue.increment(1),
        FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  /// Appends many tracks at once. Used by the import path.
  ///
  /// Positions are assigned client-side in one pass rather than by calling
  /// [addTrack] in a loop, which would be one transaction and two round trips
  /// per track — minutes for a large playlist.
  Future<int> addTracks({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return 0;

    final collection = FirestorePaths.playlistTracks(_db, uid, playlistId);
    var position = await _lastPosition(uid, playlistId);
    var written = 0;

    // De-duplicated before writing, not after: the same track twice in one
    // import would otherwise be two `set` operations on one document id in a
    // single batch, which Firestore rejects outright.
    final seen = <String>{};

    for (var start = 0; start < tracks.length; start += _batchLimit - 1) {
      final batch = _db.batch();
      final end = (start + _batchLimit - 1).clamp(0, tracks.length);

      for (var i = start; i < end; i++) {
        final track = tracks[i];
        final id = track.documentId;
        if (!seen.add(id)) continue;

        position += _positionGap;
        batch.set(
          collection.doc(id),
          <String, Object?>{
            ...track.toFirestore(),
            FirestoreFields.position: position,
            FirestoreFields.createdAt: FieldValue.serverTimestamp(),
          },
          // Merge so a re-import refreshes metadata — a better artwork URL, a
          // corrected title — without resetting `position` and scrambling an
          // order the user may have arranged by hand.
          SetOptions(merge: true),
        );
        written++;
      }

      await batch.commit();
    }

    // Recounted rather than incremented by `written`. The merge above means
    // some of those writes updated existing rows, so an increment would drift
    // upward on every re-import until the count no longer matched the list.
    await _syncTrackCount(uid, playlistId);
    return written;
  }

  Future<void> removeTrack({
    required String uid,
    required String playlistId,
    required String trackId,
  }) async {
    final playlist = FirestorePaths.playlist(_db, uid, playlistId);
    final row = FirestorePaths.playlistTracks(_db, uid, playlistId).doc(trackId);

    await _db.runTransaction((transaction) async {
      final existing = await transaction.get(row);
      // Guarded so a double tap cannot drive the count below zero.
      if (!existing.exists) return;

      transaction.delete(row);
      transaction.update(playlist, <String, Object?>{
        FirestoreFields.trackCount: FieldValue.increment(-1),
        FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  /// Moves the track at [from] to [to] in the current ordering.
  ///
  /// [ordered] must be the list as the user currently sees it — the caller has
  /// it already, and passing it avoids a re-read of the whole playlist to
  /// discover an order the screen is holding.
  ///
  /// One document is written in the normal case. See the class comment for why
  /// that is the whole point of fractional positions.
  Future<void> reorder({
    required String uid,
    required String playlistId,
    required List<Track> ordered,
    required int from,
    required int to,
  }) async {
    if (from == to) return;
    if (from < 0 || from >= ordered.length) return;

    final moved = ordered[from];

    // The list as it will be, so "the neighbours" means the neighbours at the
    // destination rather than at the origin — an off-by-one here puts the track
    // one place from where it was dropped, which is the classic reorder bug.
    final reordered = <Track>[...ordered]..removeAt(from);
    final target = to.clamp(0, reordered.length);
    reordered.insert(target, moved);

    final before = target > 0 ? reordered[target - 1] : null;
    final after = target + 1 < reordered.length ? reordered[target + 1] : null;

    final beforePosition = before == null
        ? null
        : await _positionOf(uid, playlistId, before.documentId);
    final afterPosition = after == null
        ? null
        : await _positionOf(uid, playlistId, after.documentId);

    final next = _positionBetween(beforePosition, afterPosition);

    if (next == null) {
      // The gap has collapsed. Renumber everything once, then the move is
      // trivially expressible again.
      await _rebalance(uid, playlistId, reordered);
      return;
    }

    await FirestorePaths.playlistTracks(_db, uid, playlistId)
        .doc(moved.documentId)
        .update(<String, Object?>{FirestoreFields.position: next});

    await FirestorePaths.playlist(_db, uid, playlistId).update(<String, Object?>{
      FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
    });
  }

  // -------------------------------------------------------------------------
  // Positioning
  // -------------------------------------------------------------------------

  /// The position to give a track landing between two neighbours, or null when
  /// there is no room left between them.
  ///
  /// Visible for testing — the collapse case is the one worth a test, and it
  /// takes fifty real reorders to reach through the public API.
  static double? positionBetween(double? before, double? after) =>
      _positionBetween(before, after);

  static double? _positionBetween(double? before, double? after) {
    if (before == null && after == null) return _positionGap;
    if (before == null) return after! - _positionGap;
    if (after == null) return before + _positionGap;
    if (_needsRebalance(before, after)) return null;
    return before + (after - before) / 2;
  }

  static bool _needsRebalance(double before, double after) =>
      (after - before).abs() < _minimumGap;

  Future<double> _lastPosition(String uid, String playlistId) async {
    final snapshot = await FirestorePaths.playlistTracks(_db, uid, playlistId)
        .orderBy(FirestoreFields.position, descending: true)
        .limit(1)
        .get();
    if (snapshot.docs.isEmpty) return 0;
    final value = snapshot.docs.first.data()[FirestoreFields.position];
    return value is num ? value.toDouble() : 0;
  }

  Future<double?> _positionOf(
    String uid,
    String playlistId,
    String trackId,
  ) async {
    final snapshot = await FirestorePaths.playlistTracks(_db, uid, playlistId)
        .doc(trackId)
        .get();
    final value = snapshot.data()?[FirestoreFields.position];
    return value is num ? value.toDouble() : null;
  }

  /// Renumbers a whole playlist onto clean, evenly spaced positions.
  ///
  /// The expensive path, and deliberately so: it is one write per track, and it
  /// runs only when fractional positions have been subdivided to the point of
  /// collapse. In exchange, every ordinary reorder is a single write.
  Future<void> _rebalance(
    String uid,
    String playlistId,
    List<Track> ordered,
  ) async {
    AppLogger.info(
      'Rebalancing playlist $playlistId (${ordered.length} tracks)',
      scope: 'playlists',
    );

    final collection = FirestorePaths.playlistTracks(_db, uid, playlistId);

    for (var start = 0; start < ordered.length; start += _batchLimit) {
      final batch = _db.batch();
      final end = (start + _batchLimit).clamp(0, ordered.length);
      for (var i = start; i < end; i++) {
        batch.update(
          collection.doc(ordered[i].documentId),
          <String, Object?>{FirestoreFields.position: (i + 1) * _positionGap},
        );
      }
      await batch.commit();
    }

    await FirestorePaths.playlist(_db, uid, playlistId).update(<String, Object?>{
      FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
    });
  }

  /// Recomputes `trackCount` from the subcollection.
  ///
  /// Uses an aggregate `count()` query, which is billed as one read rather than
  /// one per document — the difference between a cheap correction and a reason
  /// to avoid correcting.
  Future<void> _syncTrackCount(String uid, String playlistId) async {
    try {
      final count = await FirestorePaths.playlistTracks(_db, uid, playlistId)
          .count()
          .get();
      await FirestorePaths.playlist(_db, uid, playlistId).update(
        <String, Object?>{
          FirestoreFields.trackCount: count.count ?? 0,
          FirestoreFields.updatedAt: FieldValue.serverTimestamp(),
        },
      );
    } on Object catch (error) {
      // A wrong count is a cosmetic subtitle, not a broken playlist. The rows
      // themselves are already written, and the next edit corrects it.
      AppLogger.warn(
        'Could not sync track count for $playlistId',
        scope: 'playlists',
        error: error,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------------

  List<Playlist> _playlistsFrom(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final out = <Playlist>[];
    for (final doc in snapshot.docs) {
      try {
        out.add(Playlist.fromFirestore(doc.id, doc.data()));
      } on Object catch (error) {
        AppLogger.warn(
          'Skipping unreadable playlist ${doc.id}',
          scope: 'playlists',
          error: error,
        );
      }
    }
    return out;
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
          'Skipping unreadable track ${doc.id}',
          scope: 'playlists',
          error: error,
        );
      }
    }

    // Re-sorted client-side even though the query ordered by `position`.
    //
    // Two rows can share a position — see the race noted in `addTrack` — and
    // Firestore's tie-break for equal sort keys is document id, which is a
    // hash-like string. Breaking the tie on document id explicitly makes the
    // order the same on every device rather than merely stable per query.
    rows.sort((a, b) {
      final byPosition = a.position.compareTo(b.position);
      if (byPosition != 0) return byPosition;
      return a.track.id.compareTo(b.track.id);
    });

    return rows.map((row) => row.track).toList(growable: false);
  }
}
