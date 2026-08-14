import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/spotify_endpoints.dart';
import '../../core/utils/app_logger.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/json_utils.dart';
import '../models/paging.dart';
import '../models/saved_item.dart';
import '../models/track.dart';
import '../models/user_profile.dart';
import 'spotify_api_service.dart';

/// How far back `/me/top/*` looks.
enum TopItemRange {
  shortTerm('short_term', 'Last 4 weeks'),
  mediumTerm('medium_term', 'Last 6 months'),
  longTerm('long_term', 'All time');

  const TopItemRange(this.apiValue, this.label);
  final String apiValue;
  final String label;
}

/// Profile, library and follow endpoints for the signed-in user.
class SpotifyUserService extends SpotifyApiService {
  SpotifyUserService(super.dio);

  // ---- Profile -----------------------------------------------------------

  Future<UserProfile> me({CancelToken? cancelToken}) => get<UserProfile>(
    SpotifyEndpoints.me,
    UserProfile.fromJson,
    cancelToken: cancelToken,
  );

  Future<UserProfile> user(String id, {CancelToken? cancelToken}) =>
      get<UserProfile>(
        SpotifyEndpoints.userProfile(id),
        UserProfile.fromJson,
        cancelToken: cancelToken,
      );

  // ---- Taste -------------------------------------------------------------

  Future<Paging<Artist>> topArtists({
    TopItemRange range = TopItemRange.mediumTerm,
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<Artist>>(
    SpotifyEndpoints.myTopArtists,
    (json) => Paging<Artist>.fromJson(json, Artist.fromJson),
    query: <String, dynamic>{
      'time_range': range.apiValue,
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
    },
    cancelToken: cancelToken,
  );

  Future<Paging<Track>> topTracks({
    TopItemRange range = TopItemRange.mediumTerm,
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<Track>>(
    SpotifyEndpoints.myTopTracks,
    (json) => Paging<Track>.fromJson(json, Track.fromJson),
    query: <String, dynamic>{
      'time_range': range.apiValue,
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
    },
    cancelToken: cancelToken,
  );

  // ---- Library: tracks ---------------------------------------------------

  Future<Paging<SavedTrack>> savedTracks({
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<SavedTrack>>(
    SpotifyEndpoints.mySavedTracks,
    (json) => Paging<SavedTrack>.fromJson(json, SavedTrack.fromJson),
    query: <String, dynamic>{
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
      'market': SpotifyApiService.market,
    },
    cancelToken: cancelToken,
  );

  Future<void> saveTracks(List<String> ids) =>
      _libraryWrite(_trackUris(ids), add: true);

  Future<void> removeTracks(List<String> ids) =>
      _libraryWrite(_trackUris(ids), add: false);

  Future<List<bool>> areTracksSaved(List<String> ids, {CancelToken? cancelToken}) =>
      _libraryContains(
        ids.map((id) => 'spotify:track:$id').toList(growable: false),
        cancelToken: cancelToken,
      );

  // ---- Library: albums ---------------------------------------------------

  Future<Paging<SavedAlbum>> savedAlbums({
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<SavedAlbum>>(
    SpotifyEndpoints.mySavedAlbums,
    (json) => Paging<SavedAlbum>.fromJson(json, SavedAlbum.fromJson),
    query: <String, dynamic>{
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
      'market': SpotifyApiService.market,
    },
    cancelToken: cancelToken,
  );

  Future<void> saveAlbums(List<String> ids) =>
      _libraryWrite(_albumUris(ids), add: true);

  Future<void> removeAlbums(List<String> ids) =>
      _libraryWrite(_albumUris(ids), add: false);

  Future<List<bool>> areAlbumsSaved(List<String> ids, {CancelToken? cancelToken}) =>
      _libraryContains(
        ids.map((id) => 'spotify:album:$id').toList(growable: false),
        cancelToken: cancelToken,
      );

  // ---- Follows -----------------------------------------------------------

  /// Followed artists. Cursor-paged — there is no offset variant.
  Future<CursorPaging<Artist>> followedArtists({
    int limit = 50,
    String? after,
    CancelToken? cancelToken,
  }) => get<CursorPaging<Artist>>(
    SpotifyEndpoints.myFollowing,
    (json) {
      final artists = Json.obj(json, 'artists');
      return artists == null
          ? CursorPaging.empty<Artist>()
          : CursorPaging<Artist>.fromJson(artists, Artist.fromJson);
    },
    query: <String, dynamic>{
      'type': 'artist',
      'limit': SpotifyApiService.clampLimit(limit),
      'after': ?after,
    },
    cancelToken: cancelToken,
  );

  Future<void> followArtists(List<String> ids) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.myFollowing,
      queryParameters: <String, dynamic>{'type': 'artist'},
      data: <String, dynamic>{'ids': ids},
    ),
  );

  Future<void> unfollowArtists(List<String> ids) => command(
    () => dio.delete<dynamic>(
      SpotifyEndpoints.myFollowing,
      queryParameters: <String, dynamic>{'type': 'artist'},
      data: <String, dynamic>{'ids': ids},
    ),
  );

  Future<List<bool>> areArtistsFollowed(
    List<String> ids, {
    CancelToken? cancelToken,
  }) async {
    if (ids.isEmpty) return const [];
    return getBoolArray(
      SpotifyEndpoints.myFollowingContains,
      query: <String, dynamic>{'type': 'artist', 'ids': ids.join(',')},
      cancelToken: cancelToken,
    );
  }

  // ---- History -----------------------------------------------------------

  /// `/me/player/recently-played`.
  ///
  /// Spotify caps this at the 50 most recent plays and returns duplicates when
  /// a track was played more than once — the repository de-duplicates before
  /// showing it as a shelf.
  Future<CursorPaging<PlayHistoryEntry>> recentlyPlayed({
    int limit = 50,
    CancelToken? cancelToken,
  }) => get<CursorPaging<PlayHistoryEntry>>(
    SpotifyEndpoints.playerRecentlyPlayed,
    (json) => CursorPaging<PlayHistoryEntry>.fromJson(json, PlayHistoryEntry.fromJson),
    query: <String, dynamic>{'limit': SpotifyApiService.clampLimit(limit)},
    cancelToken: cancelToken,
    onEmpty: CursorPaging.empty<PlayHistoryEntry>,
  );

  // ---- Internals ---------------------------------------------------------

  static List<String> _trackUris(List<String> ids) => _uris('track', ids);
  static List<String> _albumUris(List<String> ids) => _uris('album', ids);

  /// Turns bare IDs into Spotify URIs, dropping empties.
  ///
  /// An empty ID would build `spotify:track:` and take the whole batch down
  /// with a `400` — local files carry no ID, and they reach here through
  /// "save this track" like anything else.
  static List<String> _uris(String type, List<String> ids) => ids
      .where((id) => id.isNotEmpty)
      .map((id) => id.startsWith('spotify:') ? id : 'spotify:$type:$id')
      .toList(growable: false);

  /// `PUT`/`DELETE /me/library?uris=…` — every library write in the app.
  ///
  /// Replaces the per-type `PUT`/`DELETE /me/tracks` and `/me/albums` this used
  /// to send. Those were removed for Development Mode applications in February
  /// 2026 and answer `403` unconditionally, which is the failure behind a heart
  /// that flicked full and snapped back.
  ///
  /// Two details are load-bearing and neither survives a naive port:
  ///
  ///  * **`uris` is a query parameter.** The old endpoints took
  ///    `{"ids": [...]}` as a JSON body. Sending a body here is a `400`, which
  ///    would look like the same bug with a different number.
  ///  * **The cap is 40**, below both of the old per-type limits (50 for
  ///    tracks, 20 for albums), so chunking is uniform now rather than
  ///    per-type.
  ///
  /// Failures propagate as [ApiException]. Callers roll their optimistic UI
  /// back on one — silently swallowing it is what let the app claim a save
  /// Spotify had refused.
  Future<void> _libraryWrite(List<String> uris, {required bool add}) async {
    if (uris.isEmpty) return;

    for (final batch in SpotifyApiService.chunk(
      uris,
      AppConstants.maxLibraryContainsUris,
    )) {
      final query = <String, dynamic>{'uris': batch.join(',')};
      await command(
        () => add
            ? dio.put<dynamic>(SpotifyEndpoints.library, queryParameters: query)
            : dio.delete<dynamic>(SpotifyEndpoints.library, queryParameters: query),
      );
    }
    AppLogger.info(
      '${add ? 'Saved' : 'Removed'} ${uris.length} item(s)',
      scope: 'library',
    );
  }

  /// `GET /me/library/contains`, batched.
  ///
  /// Replaced the per-type `_contains` helper in February 2026. Three
  /// differences from the endpoint it supersedes, all of which this method
  /// exists to absorb:
  ///
  ///  * it takes Spotify **URIs**, so callers convert their IDs first;
  ///  * the cap is **40**, not 50 — chunking at the old size would 400;
  ///  * one endpoint serves every type, so a mixed list would be legal. The
  ///    callers here keep to one type each, because they answer per-type
  ///    questions ("is this album saved?").
  ///
  /// The response is positional, so chunks are concatenated in order and a
  /// short page is padded with `false` rather than shifting every heart after
  /// it onto the wrong row.
  Future<List<bool>> _libraryContains(
    List<String> uris, {
    CancelToken? cancelToken,
  }) async {
    if (uris.isEmpty) return const [];

    final results = <bool>[];
    for (final batch in SpotifyApiService.chunk(
      uris,
      AppConstants.maxLibraryContainsUris,
    )) {
      final page = await getBoolArray(
        SpotifyEndpoints.libraryContains,
        query: <String, dynamic>{'uris': batch.join(',')},
        cancelToken: cancelToken,
      );
      results.addAll(
        page.length == batch.length
            ? page
            : List<bool>.filled(batch.length, false),
      );
    }
    return results;
  }

  // ---- Albums used by library screens ------------------------------------

  /// Convenience for the library grid, which only needs the albums.
  Future<List<Album>> savedAlbumsFlat({
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final page = await savedAlbums(limit: limit, offset: offset, cancelToken: cancelToken);
    return page.items.map((s) => s.album).toList(growable: false);
  }
}
