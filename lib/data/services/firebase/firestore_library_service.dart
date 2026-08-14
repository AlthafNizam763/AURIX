import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/utils/app_logger.dart';
import '../../models/json_utils.dart';
import '../../models/saved_item.dart';
import '../../models/track.dart';
import 'firestore_paths.dart';

/// Liked songs and listening history.
///
/// ```
/// /users/{uid}/likedTracks/{trackId}
/// /users/{uid}/recentlyPlayed/{itemId}
/// ```
///
/// Both replace a Spotify endpoint that AURIX no longer calls — `/me/tracks`
/// and `/me/player/recently-played` — and both are better for it in one
/// specific way: they record what happened *in AURIX*. The old recently-played
/// shelf showed what the user had played on Spotify, on any device, including
/// things AURIX had never been open for.
class FirestoreLibraryService {
  FirestoreLibraryService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const int _batchLimit = 500;

  /// How many history entries to keep.
  ///
  /// History is append-only and would otherwise grow without bound — a document
  /// per play, forever, on a collection that is read in full on every launch.
  /// The cap is enforced on write; see [_trimHistory].
  static const int historyLimit = 200;

  // -------------------------------------------------------------------------
  // Liked songs
  // -------------------------------------------------------------------------

  /// Every liked track, most recently liked first.
  Stream<List<Track>> watchLikedTracks(String uid, {int limit = 500}) =>
      FirestorePaths.likedTracksOf(_db, uid)
          .orderBy(FirestoreFields.createdAt, descending: true)
          .limit(limit)
          .snapshots()
          .map(_tracksFrom)
          .handleError((Object error, StackTrace stackTrace) {
            AppLogger.error(
              'Liked tracks stream failed',
              scope: 'library',
              error: error,
              stackTrace: stackTrace,
            );
          });

  Future<List<Track>> readLikedTracks(String uid, {int limit = 500}) async {
    final snapshot = await FirestorePaths.likedTracksOf(_db, uid)
        .orderBy(FirestoreFields.createdAt, descending: true)
        .limit(limit)
        .get();
    return _tracksFrom(snapshot);
  }

  /// Likes a track.
  ///
  /// The document id is [Track.documentId], so liking the same song twice
  /// writes the same document twice rather than creating two rows — which is
  /// what makes the heart idempotent across screens and devices.
  ///
  /// `merge` so that a like arriving from a screen with richer metadata (the
  /// full player, which has artwork and album) improves the stored row rather
  /// than a sparser one from a search result overwriting it with blanks.
  Future<void> like(String uid, Track track) async {
    final id = track.documentId;
    await FirestorePaths.likedTracksOf(_db, uid).doc(id).set(
      <String, Object?>{
        ...track.toFirestore(),
        FirestoreFields.createdAt: FieldValue.serverTimestamp(),
      },
      SetOptions(merge: true),
    );
    AppLogger.info('Liked $id', scope: 'library');
  }

  Future<void> unlike(String uid, Track track) async {
    final id = track.documentId;
    await FirestorePaths.likedTracksOf(_db, uid).doc(id).delete();
    AppLogger.info('Unliked $id', scope: 'library');
  }

  /// Whether one track is liked.
  Future<bool> isLiked(String uid, String trackId) async {
    final snapshot =
        await FirestorePaths.likedTracksOf(_db, uid).doc(trackId).get();
    return snapshot.exists;
  }

  /// Which of [trackIds] are liked.
  ///
  /// Batched into `whereIn` queries of 30 — Firestore's limit for that
  /// operator. Reading the whole liked collection would be simpler and is what
  /// this replaced; it is also unbounded, and the answer is needed while
  /// scrolling a list.
  Future<Set<String>> likedAmong(String uid, List<String> trackIds) async {
    if (trackIds.isEmpty) return const <String>{};

    const chunkSize = 30;
    final unique = trackIds.where((id) => id.isNotEmpty).toSet().toList();
    final liked = <String>{};

    for (var start = 0; start < unique.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, unique.length);
      final chunk = unique.sublist(start, end);
      final snapshot = await FirestorePaths.likedTracksOf(_db, uid)
          .where(FieldPath.documentId, whereIn: chunk)
          .get();
      for (final doc in snapshot.docs) {
        liked.add(doc.id);
      }
    }

    return liked;
  }

  // -------------------------------------------------------------------------
  // Recently played
  // -------------------------------------------------------------------------

  /// Play history, most recent first.
  Stream<List<PlayHistoryEntry>> watchRecentlyPlayed(
    String uid, {
    int limit = 50,
  }) => FirestorePaths.recentlyPlayedOf(_db, uid)
      .orderBy(FirestoreFields.playedAt, descending: true)
      .limit(limit)
      .snapshots()
      .map(_historyFrom)
      .handleError((Object error, StackTrace stackTrace) {
        AppLogger.error(
          'Recently played stream failed',
          scope: 'library',
          error: error,
          stackTrace: stackTrace,
        );
      });

  Future<List<PlayHistoryEntry>> readRecentlyPlayed(
    String uid, {
    int limit = 50,
  }) async {
    final snapshot = await FirestorePaths.recentlyPlayedOf(_db, uid)
        .orderBy(FirestoreFields.playedAt, descending: true)
        .limit(limit)
        .get();
    return _historyFrom(snapshot);
  }

  /// Records a play.
  ///
  /// ## Why the document id is the track, not the play
  ///
  /// The spec's `/recentlyPlayed/{itemId}` could be a fresh id per play, giving
  /// a true log. It is the track's id instead, so playing the same song ten
  /// times leaves one row whose `playedAt` moves.
  ///
  /// That is what the feature actually is. Every consumer — the Home shelf, the
  /// Recently Played list — wants distinct tracks in recency order, and the old
  /// Spotify-backed shelf had to de-duplicate the endpoint's log in application
  /// code to get there. Collapsing on write means the collection is bounded by
  /// distinct tracks rather than by total plays, no de-duplication is needed on
  /// read, and the ten writes are ten updates to one document instead of ten
  /// new ones.
  ///
  /// The cost is that the history cannot answer "how many times did I play
  /// this" — nothing in AURIX asks.
  Future<void> recordPlay(
    String uid,
    Track track, {
    Duration position = Duration.zero,
  }) async {
    final id = track.documentId;
    try {
      await FirestorePaths.recentlyPlayedOf(_db, uid).doc(id).set(
        <String, Object?>{
          ...track.toFirestore(),
          'trackId': id,
          FirestoreFields.playedAt: FieldValue.serverTimestamp(),
          'position': position.inMilliseconds,
          'duration': track.durationMs,
        },
        SetOptions(merge: true),
      );
    } on Object catch (error) {
      // History is a convenience. A failure to record a play must never
      // interrupt the play itself, so this is logged and dropped rather than
      // propagated to the player.
      AppLogger.debug('Could not record play of $id: $error', scope: 'library');
      return;
    }

    unawaited(_trimHistory(uid));
  }

  /// Drops the oldest entries once the collection exceeds [historyLimit].
  ///
  /// Fire-and-forget from [recordPlay]: it is housekeeping, and making the
  /// caller wait for it would put a write on the critical path of pressing
  /// play.
  Future<void> _trimHistory(String uid) async {
    try {
      final collection = FirestorePaths.recentlyPlayedOf(_db, uid);
      // Ordered oldest-first and skipping the newest `historyLimit`, so
      // whatever comes back is exactly the excess.
      final excess = await collection
          .orderBy(FirestoreFields.playedAt, descending: true)
          .limit(_batchLimit)
          .get();

      if (excess.docs.length <= historyLimit) return;

      final batch = _db.batch();
      for (final doc in excess.docs.skip(historyLimit)) {
        batch.delete(doc.reference);
      }
      await batch.commit();
    } on Object catch (error) {
      AppLogger.debug('History trim failed: $error', scope: 'library');
    }
  }

  Future<void> clearHistory(String uid) async {
    final collection = FirestorePaths.recentlyPlayedOf(_db, uid);
    while (true) {
      final page = await collection.limit(_batchLimit).get();
      if (page.docs.isEmpty) return;

      final batch = _db.batch();
      for (final doc in page.docs) {
        batch.delete(doc.reference);
      }
      await batch.commit();

      if (page.docs.length < _batchLimit) return;
    }
  }

  // -------------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------------

  List<Track> _tracksFrom(QuerySnapshot<Map<String, dynamic>> snapshot) {
    final out = <Track>[];
    for (final doc in snapshot.docs) {
      try {
        out.add(Track.fromFirestore(doc.id, doc.data()));
      } on Object catch (error) {
        AppLogger.warn(
          'Skipping unreadable track ${doc.id}',
          scope: 'library',
          error: error,
        );
      }
    }
    return out;
  }

  List<PlayHistoryEntry> _historyFrom(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) {
    final out = <PlayHistoryEntry>[];
    for (final doc in snapshot.docs) {
      try {
        final data = doc.data();
        out.add(
          PlayHistoryEntry(
            track: Track.fromFirestore(doc.id, data),
            // Null in the window between an optimistic local write and the
            // server's timestamp landing. Treated as "just now", which is what
            // it is — the alternative would drop the row the user just played
            // out of the list they are looking at.
            playedAt: Json.timestamp(data, FirestoreFields.playedAt) ??
                DateTime.now(),
            position: Duration(milliseconds: Json.intVal(data, 'position')),
          ),
        );
      } on Object catch (error) {
        AppLogger.warn(
          'Skipping unreadable history entry ${doc.id}',
          scope: 'library',
          error: error,
        );
      }
    }
    return out;
  }
}
