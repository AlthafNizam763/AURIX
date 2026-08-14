import 'package:dio/dio.dart';

import '../../core/constants/spotify_endpoints.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/app_logger.dart';
import '../models/json_utils.dart';
import '../models/paging.dart';
import '../models/playlist.dart';
import 'spotify_api_service.dart';

/// Playlist endpoints, including the mutating ones.
class SpotifyPlaylistService extends SpotifyApiService {
  SpotifyPlaylistService(super.dio);

  Future<Playlist> playlist(String id, {CancelToken? cancelToken}) =>
      get<Playlist>(
        SpotifyEndpoints.playlist(id),
        Playlist.fromJson,
        query: <String, dynamic>{
          'market': SpotifyApiService.market,
          // `additional_types=track` keeps episodes out of `items`, which
          // would otherwise arrive as objects the track model cannot use.
          'additional_types': 'track',
        },
        cancelToken: cancelToken,
      );

  /// One page of a playlist's contents.
  ///
  /// Returns null when Spotify will not serve the contents to this application
  /// at all — which is a different answer from an empty page, and the caller
  /// has to be able to tell them apart. Rendering "this playlist is empty" over
  /// a refusal is the bug this distinction exists to prevent.
  ///
  /// Two endpoints are tried because Spotify renamed this collection in
  /// February 2026 and both spellings are live depending on the application's
  /// quota mode. The working one is discovered once and remembered for the
  /// session by [SpotifyApiService.markUnavailable], so the loser costs one
  /// request per session rather than one per page.
  Future<Paging<PlaylistItem>?> playlistItemsPage(
    String id, {
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final query = <String, dynamic>{
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
      'market': SpotifyApiService.market,
      'additional_types': 'track',
    };

    for (final path in <String>[
      SpotifyEndpoints.playlistItems(id),
      SpotifyEndpoints.playlistTracks(id),
    ]) {
      // The memo is keyed on the path, which includes the playlist ID — so a
      // refusal is remembered per playlist rather than being generalised from
      // one private playlist to every playlist in the app.
      if (SpotifyApiService.isKnownUnavailable(path)) continue;

      try {
        return await get<Paging<PlaylistItem>>(
          path,
          (json) => Paging<PlaylistItem>.fromJson(json, PlaylistItem.fromJson),
          query: query,
          cancelToken: cancelToken,
        );
      } on ApiException catch (error) {
        if (error.kind != ApiFailureKind.forbidden &&
            error.kind != ApiFailureKind.notFound) {
          // A timeout or a 500 is not a capability answer — it must surface as
          // an error rather than being downgraded to "unavailable", which would
          // permanently silence a retryable failure.
          rethrow;
        }
        SpotifyApiService.markUnavailable(path, error);
      }
    }

    AppLogger.warn(
      'Contents unavailable for playlist $id — Spotify refused both '
      '/items and /tracks for this application',
      scope: 'playlist',
    );
    return null;
  }

  /// Loads a playlist with its first pages of contents resolved.
  ///
  /// [Playlist.items] afterwards means exactly one of three things, and the UI
  /// depends on being able to tell them apart:
  ///
  ///  * a page with entries — the normal case;
  ///  * an **empty** page — a genuinely empty playlist;
  ///  * **null** — Spotify would not serve the contents to this application.
  ///
  /// The previous version returned early whenever the detail response carried
  /// no inline contents, so it never asked the collection endpoint at all. That
  /// is the "200 OK, 0 songs, this playlist is empty" bug: the request
  /// succeeded, the metadata parsed, and the tracks were simply never fetched.
  ///
  /// Bounded at [maxTracks]: some public playlists run to 10,000 entries, and
  /// pulling all of them would be 200 requests and a lot of memory for a screen
  /// that will only ever show a few hundred rows. The UI pages the rest on
  /// scroll.
  Future<Playlist> playlistWithTracks(
    String id, {
    int maxTracks = 300,
    CancelToken? cancelToken,
  }) async {
    final playlist = await this.playlist(id, cancelToken: cancelToken);

    // The detail response usually inlines the first page. When it does not —
    // which is what happens on the accounts this bug was reported from — ask
    // for it rather than reporting the playlist as empty.
    var items = playlist.items;
    if (items == null) {
      AppLogger.info(
        'Detail response carried no contents; fetching first page',
        scope: 'playlist',
      );
      items = await playlistItemsPage(id, cancelToken: cancelToken);
      if (items == null) {
        AppLogger.info(
          'id=$id total=${playlist.trackCount} loaded=unavailable',
          scope: 'playlist',
        );
        return playlist;
      }
    }

    while (items!.hasMore && items.items.length < maxTracks) {
      final next = await playlistItemsPage(
        id,
        limit: 50,
        offset: items.items.length,
        cancelToken: cancelToken,
      );
      if (next == null || next.items.isEmpty) break;
      items = items.append(next);
    }

    AppLogger.info(
      'id=$id total=${items.total} loaded=${items.items.length}',
      scope: 'playlist',
    );

    // `total` from the contents page is authoritative when the detail
    // response's own count was missing — that count is what rendered as
    // "0 songs" beside a playlist that plainly had some.
    return playlist.copyWith(
      items: items,
      trackCount: playlist.trackCount > 0 ? playlist.trackCount : items.total,
    );
  }

  /// Playlists owned or followed by the signed-in user.
  Future<Paging<Playlist>> myPlaylists({
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<Playlist>>(
    SpotifyEndpoints.myPlaylists,
    (json) => Paging<Playlist>.fromJson(json, Playlist.fromJson),
    query: <String, dynamic>{
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
    },
    cancelToken: cancelToken,
  );

  Future<Paging<Playlist>> userPlaylists(
    String userId, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<Playlist>>(
    SpotifyEndpoints.userPlaylists(userId),
    (json) => Paging<Playlist>.fromJson(json, Playlist.fromJson),
    query: <String, dynamic>{
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
    },
    cancelToken: cancelToken,
  );

  // ---- Follow / unfollow -------------------------------------------------

  /// "Save" a playlist. Spotify models this as following, not saving.
  ///
  /// Goes through `PUT /me/library?uris=spotify:playlist:{id}` — February 2026
  /// replaced `PUT /playlists/{id}/followers` along with the rest of the
  /// library writes, and the old path now answers `403`.
  ///
  /// The `public` flag has no equivalent on the consolidated endpoint, so it is
  /// gone rather than silently ignored: the playlist is saved to the library,
  /// which is what the button says it does.
  Future<void> follow(String id) => command(
    () => dio.put<dynamic>(
      SpotifyEndpoints.library,
      queryParameters: <String, dynamic>{'uris': _playlistUri(id)},
    ),
  );

  Future<void> unfollow(String id) => command(
    () => dio.delete<dynamic>(
      SpotifyEndpoints.library,
      queryParameters: <String, dynamic>{'uris': _playlistUri(id)},
    ),
  );

  static String _playlistUri(String id) =>
      id.startsWith('spotify:') ? id : 'spotify:playlist:$id';

  /// Whether [userId] follows (i.e. has saved) the playlist.
  ///
  /// Whether the signed-in user has saved (followed) this playlist.
  ///
  /// Asked through `GET /me/library/contains?uris=spotify:playlist:{id}`. The
  /// previous version called `GET /playlists/{id}/followers/contains`, which
  /// February 2026 folded into the library endpoint — and which produced the
  /// `403 GET /playlists/{id}/followers/contains` in the logs. That refusal was
  /// already handled gracefully, so the page loaded; the cost was that the
  /// heart was permanently indeterminate on every playlist. On the current
  /// endpoint it gets a real answer.
  ///
  /// Note the check is no longer *about* a user: the old endpoint asked
  /// "does user X follow this playlist", the library endpoint asks "is this in
  /// my library", so the caller's user ID is not needed and is not sent.
  ///
  /// **Null means unknown, and that is not the same as false.** Deliberately
  /// not routed through [getBoolArray], which flattens a refusal to an empty
  /// list — `result.first` on that would render "not saved" for a playlist the
  /// user may well have saved. An unfilled heart is a claim about the user's
  /// library; the app is not entitled to make it when Spotify declined to
  /// answer. A refusal is remembered, so it costs one request per session
  /// rather than one per playlist opened.
  Future<bool?> isFollowing(String playlistId, {CancelToken? cancelToken}) async {
    if (playlistId.isEmpty) return null;

    const path = SpotifyEndpoints.libraryContains;
    if (SpotifyApiService.isKnownUnavailable(path)) return null;

    try {
      final result = await getArray<bool>(
        path,
        (element) => element is bool && element,
        query: <String, dynamic>{'uris': _playlistUri(playlistId)},
        cancelToken: cancelToken,
      );
      return result.isEmpty ? null : result.first;
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden ||
          error.kind == ApiFailureKind.notFound) {
        SpotifyApiService.markUnavailable(path, error);
        return null;
      }
      rethrow;
    }
  }

  // ---- Mutations ---------------------------------------------------------

  /// Appends tracks. [uris] must be Spotify track URIs.
  Future<String?> addTracks(String playlistId, List<String> uris) async {
    if (uris.isEmpty) return null;
    String? snapshot;
    // The endpoint accepts 100 URIs per call.
    for (final batch in SpotifyApiService.chunk(uris, 100)) {
      final response = await dio.post<dynamic>(
        SpotifyEndpoints.playlistTracks(playlistId),
        data: <String, dynamic>{'uris': batch},
      );
      final data = response.data;
      if (data is Map<String, dynamic>) {
        snapshot = Json.strOrNull(data, 'snapshot_id') ?? snapshot;
      }
    }
    return snapshot;
  }

  /// Removes every occurrence of [uris].
  ///
  /// [snapshotId] is not optional in spirit: without it a concurrent edit from
  /// another device can cause the wrong track to be removed, because positions
  /// shift underneath the request.
  Future<String?> removeTracks(
    String playlistId,
    List<String> uris, {
    String? snapshotId,
  }) async {
    if (uris.isEmpty) return null;
    final response = await dio.delete<dynamic>(
      SpotifyEndpoints.playlistTracks(playlistId),
      data: <String, dynamic>{
        'tracks': uris.map((uri) => <String, dynamic>{'uri': uri}).toList(),
        'snapshot_id': ?snapshotId,
      },
    );
    final data = response.data;
    return data is Map<String, dynamic> ? Json.strOrNull(data, 'snapshot_id') : null;
  }

  /// Moves [length] tracks starting at [from] to sit before index [to].
  Future<String?> reorder(
    String playlistId, {
    required int from,
    required int to,
    int length = 1,
    String? snapshotId,
  }) async {
    final response = await dio.put<dynamic>(
      SpotifyEndpoints.playlistTracks(playlistId),
      data: <String, dynamic>{
        'range_start': from,
        'insert_before': to,
        'range_length': length,
        'snapshot_id': ?snapshotId,
      },
    );
    final data = response.data;
    return data is Map<String, dynamic> ? Json.strOrNull(data, 'snapshot_id') : null;
  }
}
