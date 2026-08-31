import 'package:dio/dio.dart';

import '../../core/constants/spotify_endpoints.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/json_utils.dart';
import '../models/paging.dart';
import '../models/track.dart';
import 'spotify_api_service.dart';
import 'spotify_search_service.dart';

/// Artist endpoints, including a fallback for related artists.
class SpotifyArtistService extends SpotifyApiService {
  SpotifyArtistService(super.dio, {SpotifySearchService? searchService})
    : _search = searchService ?? SpotifySearchService(dio);

  final SpotifySearchService _search;

  static const int _batchLimit = 50;

  Future<Artist> artist(String id, {CancelToken? cancelToken}) => get<Artist>(
    SpotifyEndpoints.artist(id),
    Artist.fromJson,
    cancelToken: cancelToken,
  );

  Future<List<Artist>> artists(List<String> ids, {CancelToken? cancelToken}) async {
    if (ids.isEmpty) return const [];

    final results = <Artist>[];
    for (final batch in SpotifyApiService.chunk(ids, _batchLimit)) {
      final page = await get<List<Artist>>(
        SpotifyEndpoints.artists,
        (json) => Json.list(json, 'artists', Artist.fromJson),
        query: <String, dynamic>{'ids': batch.join(',')},
        cancelToken: cancelToken,
      );
      results.addAll(page);
    }
    return results;
  }

  /// Up to 10 tracks, ordered by popularity in the current market.
  Future<List<Track>> topTracks(String id, {CancelToken? cancelToken}) =>
      get<List<Track>>(
        SpotifyEndpoints.artistTopTracks(id),
        (json) => Json.list(json, 'tracks', Track.fromJson),
        query: <String, dynamic>{'market': SpotifyApiService.market},
        cancelToken: cancelToken,
      );

  /// The artist's discography, filtered by release group.
  ///
  /// `include_groups` is what separates the "Albums", "Singles & EPs" and
  /// "Appears on" sections of the artist screen — without it Spotify returns
  /// everything interleaved.
  Future<Paging<Album>> albums(
    String id, {
    List<AlbumType> groups = const [AlbumType.album],
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => get<Paging<Album>>(
    SpotifyEndpoints.artistAlbums(id),
    (json) => Paging<Album>.fromJson(json, Album.fromJson),
    query: <String, dynamic>{
      'include_groups': groups.map(_groupValue).join(','),
      'limit': SpotifyApiService.clampLimit(limit),
      'offset': offset,
      'market': SpotifyApiService.market,
    },
    cancelToken: cancelToken,
  );

  Future<Paging<Album>> singles(
    String id, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => albums(
    id,
    groups: const [AlbumType.single],
    limit: limit,
    offset: offset,
    cancelToken: cancelToken,
  );

  Future<Paging<Album>> appearsOn(
    String id, {
    int limit = 20,
    CancelToken? cancelToken,
  }) => albums(
    id,
    groups: const [AlbumType.appearsOn, AlbumType.compilation],
    limit: limit,
    cancelToken: cancelToken,
  );

  /// Related artists.
  ///
  /// `/artists/{id}/related-artists` is one of the endpoints Spotify restricted
  /// in November 2024, so apps without extended quota get a 403. The fallback
  /// searches the artist's own genres — the results are real Spotify artists in
  /// the same genre, which is an honest approximation rather than a fabricated
  /// list. When the fallback cannot run either (the artist has no genres),
  /// this returns empty and the UI hides the section.
  Future<List<Artist>> relatedArtists(
    String id, {
    List<String> genreHints = const [],
    String? excludeName,
    int limit = 10,
    CancelToken? cancelToken,
  }) async {
    // `/artists/{id}/related-artists` used to be tried first here. Spotify
    // restricted it on 27 November 2024, so it answers 403 to every request
    // this app can make — one refused round trip per artist screen, for a
    // result that was always going to come from the genre search below.
    if (genreHints.isEmpty) return const [];

    // Two genres is enough signal; more just narrows the result set to noise.
    final query = genreHints
        .take(2)
        .map((g) => 'genre:"$g"')
        .join(' ');

    final page = await _search.searchArtists(
      query,
      limit: limit + 4,
      cancelToken: cancelToken,
    );

    return page.items
        .where((a) => a.id != id && a.name != excludeName)
        .take(limit)
        .toList(growable: false);
  }

  /// Playlists that feature the artist. Spotify has no "artist playlists"
  /// endpoint; searching the artist name against playlists is the documented
  /// way to surface this, and returns real playlists.
  Future<List<Object>> artistPlaylists(
    String artistName, {
    int limit = 10,
    CancelToken? cancelToken,
  }) async {
    final page = await _search.searchPlaylists(
      artistName,
      limit: limit,
      cancelToken: cancelToken,
    );
    return page.items;
  }

  String _groupValue(AlbumType type) {
    switch (type) {
      case AlbumType.album:
        return 'album';
      case AlbumType.single:
        return 'single';
      case AlbumType.compilation:
        return 'compilation';
      case AlbumType.appearsOn:
        return 'appears_on';
    }
  }
}
