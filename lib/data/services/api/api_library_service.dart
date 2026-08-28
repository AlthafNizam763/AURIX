import 'dart:async';

import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/json_utils.dart';
import '../../models/saved_item.dart';
import '../../models/track.dart';
import 'live_query.dart';

/// Liked songs and listening history — the replacement for
/// `FirestoreLibraryService`.
///
/// ```
/// GET    /library/liked
/// PUT    /library/liked/{trackId}
/// DELETE /library/liked/{trackId}
/// GET    /library/recently-played
/// POST   /library/recently-played
/// ```
///
/// Both collections replace a Spotify endpoint AURIX no longer calls —
/// `/me/tracks` and `/me/player/recently-played` — and both are better for it
/// in one specific way: they record what happened *in AURIX*. The old
/// recently-played shelf showed what the user had played on Spotify, on any
/// device, including things AURIX had never been open for.
///
/// ## The uid parameter
///
/// Every method still takes one, and the server ignores it — it resolves the
/// account from the bearer token and would refuse a request about anyone else.
/// The parameter stays because it is what the [LiveQueries] keys are built
/// from, and because removing it would touch every repository for no gain.
class ApiLibraryService {
  ApiLibraryService({required AurixApiClient client, required LiveQueries live})
    : _client = client,
      _live = live;

  final AurixApiClient _client;
  final LiveQueries _live;

  /// How many history entries the server keeps.
  ///
  /// Enforced on write, server-side — see the trim in `library.routes.js`.
  /// Declared here as well because the read limit is clamped to it, and a
  /// client asking for more than the server retains would page past the end.
  /// Keep the two in step.
  static const int historyLimit = 200;

  // -------------------------------------------------------------------------
  // Liked songs
  // -------------------------------------------------------------------------

  /// Every liked track, most recently liked first.
  Stream<List<Track>> watchLikedTracks(String uid, {int limit = 500}) =>
      _live.watch(LiveKeys.liked(uid), () => readLikedTracks(uid, limit: limit));

  Future<List<Track>> readLikedTracks(String uid, {int limit = 500}) async {
    final response = await _client.get(
      AurixEndpoints.liked,
      query: <String, dynamic>{'limit': limit},
    );
    return _tracksIn(response['tracks']);
  }

  /// Likes a track.
  ///
  /// Idempotent by construction: the server upserts on `(uid, trackId)`, so
  /// tapping the heart twice — or on two devices at once — converges on one
  /// row. That is the property `TrackKey` bought when the document id was
  /// derived from the track, preserved by a unique index instead of by a path.
  Future<void> like(String uid, Track track) async {
    await _client.put(
      AurixEndpoints.likedTrack(track.documentId),
      body: track.toDocument(),
    );
    _live.invalidate(LiveKeys.liked(uid));
  }

  Future<void> unlike(String uid, Track track) async {
    await _client.delete(AurixEndpoints.likedTrack(track.documentId));
    _live.invalidate(LiveKeys.liked(uid));
  }

  Future<bool> isLiked(String uid, String trackId) async {
    final response = await _client.get(AurixEndpoints.likedTrack(trackId));
    return response['liked'] == true;
  }

  /// Which of [trackIds] the user has liked.
  ///
  /// One request for a whole screen's worth of hearts. The Firestore version
  /// had to chunk into `whereIn` batches of thirty and stitch the results back
  /// together; `$in` has no such limit, so this is one call for a playlist.
  Future<Set<String>> likedAmong(String uid, List<String> trackIds) async {
    if (trackIds.isEmpty) return const <String>{};

    final response = await _client.post(
      AurixEndpoints.likedAmong,
      body: <String, dynamic>{'trackIds': trackIds},
    );

    final ids = response['likedIds'];
    if (ids is! List) return const <String>{};
    return ids.whereType<String>().toSet();
  }

  // -------------------------------------------------------------------------
  // Play history
  // -------------------------------------------------------------------------

  Stream<List<PlayHistoryEntry>> watchRecentlyPlayed(String uid, {int limit = 50}) =>
      _live.watch(LiveKeys.history(uid), () => readRecentlyPlayed(uid, limit: limit));

  Future<List<PlayHistoryEntry>> readRecentlyPlayed(String uid, {int limit = 50}) async {
    final response = await _client.get(
      AurixEndpoints.recentlyPlayed,
      query: <String, dynamic>{'limit': limit.clamp(1, historyLimit)},
    );

    final entries = response['entries'];
    if (entries is! List) return const <PlayHistoryEntry>[];

    final out = <PlayHistoryEntry>[];
    for (final raw in entries) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        out.add(
          PlayHistoryEntry(
            track: Track.fromDocument(Json.str(raw, 'id'), raw),
            // Absent only on a row written by a build that predates the field.
            // Treated as "just now", which keeps it at the top rather than
            // dropping it out of the list the user is looking at.
            playedAt: Json.timestamp(raw, 'playedAt') ?? DateTime.now(),
            position: Duration(milliseconds: Json.intVal(raw, 'position')),
          ),
        );
      } on Object catch (error) {
        AppLogger.warn('Skipping unreadable history entry', scope: 'library', error: error);
      }
    }
    return out;
  }

  /// Records a play.
  ///
  /// Never propagates a failure. History is a convenience, and an error here
  /// would interrupt the play itself — the one thing the app exists to do. The
  /// Firestore version made the same choice for the same reason.
  Future<void> recordPlay(
    String uid,
    Track track, {
    Duration position = Duration.zero,
  }) async {
    try {
      await _client.post(
        AurixEndpoints.recentlyPlayed,
        body: <String, dynamic>{
          'trackId': track.documentId,
          'track': track.toDocument(),
          'position': position.inMilliseconds,
        },
      );
      _live.invalidate(LiveKeys.history(uid));
    } on Object catch (error) {
      AppLogger.debug(
        'Could not record play of ${track.documentId}: $error',
        scope: 'library',
      );
    }
  }

  Future<void> clearHistory(String uid) async {
    await _client.delete(AurixEndpoints.recentlyPlayed);
    _live.invalidate(LiveKeys.history(uid));
  }

  // -------------------------------------------------------------------------
  // Parsing
  // -------------------------------------------------------------------------

  /// One malformed row never costs the whole list.
  ///
  /// The same contract the Firestore parser had, and it matters more now:
  /// a row written by a newer build with a field this one cannot read must
  /// degrade to a skipped track, not to an empty library.
  static List<Track> _tracksIn(Object? raw) {
    if (raw is! List) return const <Track>[];

    final out = <Track>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        out.add(Track.fromDocument(Json.str(entry, 'id'), entry));
      } on Object catch (error) {
        AppLogger.warn('Skipping unreadable track', scope: 'library', error: error);
      }
    }
    return out;
  }

  /// Shared with the playlist services, which parse the same row shape.
  static List<Track> tracksIn(Object? raw) => _tracksIn(raw);
}
