import 'package:dio/dio.dart';

import '../../core/constants/spotify_endpoints.dart';
import '../models/album.dart';
import '../models/json_utils.dart';
import '../models/paging.dart';
import '../models/track.dart';
import 'spotify_api_service.dart';

/// Album endpoints.
class SpotifyAlbumService extends SpotifyApiService {
  SpotifyAlbumService(super.dio);

  /// Spotify's `/albums?ids=` batch limit.
  static const int _batchLimit = 20;

  Future<Album> album(String id, {CancelToken? cancelToken}) => get<Album>(
    SpotifyEndpoints.album(id),
    Album.fromJson,
    query: <String, dynamic>{'market': SpotifyApiService.market},
    cancelToken: cancelToken,
  );

  /// Fetches several albums in one request, chunked to the API's limit.
  Future<List<Album>> albums(List<String> ids, {CancelToken? cancelToken}) async {
    if (ids.isEmpty) return const [];

    final results = <Album>[];
    for (final batch in SpotifyApiService.chunk(ids, _batchLimit)) {
      final page = await get<List<Album>>(
        SpotifyEndpoints.albums,
        (json) => Json.list(json, 'albums', Album.fromJson),
        query: <String, dynamic>{
          'ids': batch.join(','),
          'market': SpotifyApiService.market,
        },
        cancelToken: cancelToken,
      );
      results.addAll(page);
    }
    return results;
  }

  /// One track, with the album — and therefore the artwork — attached.
  ///
  /// Lives here rather than in a service of its own because the response is an
  /// album-carrying Track, which is exactly what the rest of this class deals
  /// in. Used when Spotify moves to a track AURIX did not queue: App Remote
  /// reports the title and artist but only a `spotify:image:` identifier for
  /// the cover, which is not a URL and cannot be rendered or handed to a
  /// MediaSession.
  ///
  /// Single-ID, deliberately: the multi-ID batch gets are among the endpoints
  /// Spotify closed to Development Mode apps in February 2026.
  ///
  /// Returns null rather than throwing — artwork is a nicety, and the caller
  /// already has a usable title and artist.
  Future<Track?> track(String id, {CancelToken? cancelToken}) async {
    if (id.isEmpty) return null;
    try {
      return await get<Track>(
        SpotifyEndpoints.track(id),
        Track.fromJson,
        query: <String, dynamic>{'market': SpotifyApiService.market},
        cancelToken: cancelToken,
      );
    } on Object {
      return null;
    }
  }

  /// A page of an album's tracks.
  ///
  /// Needed on top of [album] because `GET /albums/{id}` only embeds the first
  /// 50 tracks — a boxed set or a long compilation needs paging.
  ///
  /// The tracks come back without an `album` field (Spotify omits it, since
  /// the parent is implied), so [parent] is grafted on. Without it every row
  /// would render with no artwork and the player would have nothing to show.
  Future<Paging<Track>> albumTracks(
    String albumId, {
    Album? parent,
    int limit = 50,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final page = await get<Paging<Track>>(
      SpotifyEndpoints.albumTracks(albumId),
      (json) => Paging<Track>.fromJson(json, Track.fromJson),
      query: <String, dynamic>{
        'limit': SpotifyApiService.clampLimit(limit),
        'offset': offset,
        'market': SpotifyApiService.market,
      },
      cancelToken: cancelToken,
    );

    if (parent == null) return page;
    return page.map((track) => track.withAlbum(parent));
  }

  /// Loads an album along with *all* of its tracks.
  ///
  /// Used by the album screen so "Play" and "Shuffle" operate on the whole
  /// record rather than only the first page.
  Future<Album> albumWithAllTracks(String id, {CancelToken? cancelToken}) async {
    final album = await this.album(id, cancelToken: cancelToken);
    final first = album.tracks;
    if (first == null) return album;

    final withParent = first.map((t) => t.withAlbum(album));
    if (!withParent.hasMore) return album.copyWith(tracks: withParent);

    var accumulated = withParent;
    var offset = accumulated.items.length;

    // Bounded so a malformed `next` link cannot spin forever.
    while (accumulated.hasMore && offset < album.totalTracks && offset < 1000) {
      final next = await albumTracks(
        id,
        parent: album,
        limit: 50,
        offset: offset,
        cancelToken: cancelToken,
      );
      if (next.items.isEmpty) break;
      accumulated = accumulated.append(next);
      offset = accumulated.items.length;
    }

    return album.copyWith(tracks: accumulated);
  }

  // `newReleases()` used to live here, calling `GET /browse/new-releases`.
  //
  // It was removed rather than guarded. Spotify's February 2026 changes took
  // that endpoint away from Development Mode applications entirely, so it
  // answered 403 on every call this app could ever make — and four Home
  // shelves fell back to it independently, turning one Home load into five
  // refused round trips. There is no version of "retry politely" that helps.
  //
  // The shelves that used it now come from the user's own library and
  // listening history. See HomeRepository.
}
