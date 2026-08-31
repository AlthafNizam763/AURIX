import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/spotify_endpoints.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/paging.dart';
import '../models/playlist.dart';
import '../models/search_results.dart';
import '../models/track.dart';
import 'spotify_api_service.dart';

/// `GET /search`.
class SpotifySearchService extends SpotifyApiService {
  SpotifySearchService(super.dio);

  /// Searches across several types at once.
  ///
  /// Spotify returns one paging object per requested type in a single
  /// response, so asking for three costs one request rather than three.
  ///
  /// The request Spotify actually receives is
  /// `GET /search?q=…&type=track,artist,album&limit=10&offset=…&market=…`.
  /// Every part of that is load-bearing:
  ///
  ///  * **`q` is never empty.** An empty or whitespace-only query returns
  ///    empty results without touching the network — Spotify answers `400` to
  ///    a blank `q`, and a debounced text field produces plenty of them.
  ///  * **`type` is always sent**, and never empty: an empty `types` list
  ///    falls back to [SearchType.browsable] rather than omitting the
  ///    parameter, which is also a `400`.
  ///  * **`limit` never exceeds 10.** Spotify's February 2026 changes capped
  ///    search at 10 for Development Mode apps; 20 was a flat `400`.
  ///  * **`offset` is passed through** so per-tab paging keeps working.
  ///
  /// Values are not escaped by hand — Dio percent-encodes query parameters, so
  /// `q` carries spaces, quotes and non-Latin scripts (`"Arijit Singh"`,
  /// `അതിമനോഹരം`) correctly. Encoding it here as well would double-escape it.
  Future<SearchResults> searchAll(
    String query, {
    int limit = AppConstants.maxSearchPageSize,
    int offset = 0,
    List<SearchType> types = SearchType.browsable,
    CancelToken? cancelToken,
  }) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return Future.value(SearchResults.empty);

    final requested = types.isEmpty ? SearchType.browsable : types;

    return get<SearchResults>(
      SpotifyEndpoints.search,
      SearchResults.fromJson,
      query: <String, dynamic>{
        'q': trimmed,
        'type': requested.map((t) => t.apiValue).join(','),
        'limit': SpotifyApiService.clampSearchLimit(limit),
        'offset': offset < 0 ? 0 : offset,
        'market': SpotifyApiService.market,
      },
      cancelToken: cancelToken,
    );
  }

  /// Searches a single type, for the per-tab "load more" paging.
  Future<SearchResults> searchType(
    String query,
    SearchType type, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) => searchAll(
    query,
    limit: limit,
    offset: offset,
    types: <SearchType>[type],
    cancelToken: cancelToken,
  );

  Future<Paging<Track>> searchTracks(
    String query, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final results = await searchType(
      query,
      SearchType.track,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
    return results.tracks;
  }

  Future<Paging<Artist>> searchArtists(
    String query, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final results = await searchType(
      query,
      SearchType.artist,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
    return results.artists;
  }

  Future<Paging<Album>> searchAlbums(
    String query, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final results = await searchType(
      query,
      SearchType.album,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
    return results.albums;
  }

  Future<Paging<Playlist>> searchPlaylists(
    String query, {
    int limit = 20,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    final results = await searchType(
      query,
      SearchType.playlist,
      limit: limit,
      offset: offset,
      cancelToken: cancelToken,
    );
    return results.playlists;
  }

  /// Searches within a genre using Spotify's field filter.
  ///
  /// This is how AURIX populates the mood shelves now that
  /// `/browse/categories/{id}/playlists` is no longer callable. The results
  /// are genuine Spotify search results, not curated stand-ins.
  ///
  /// The one place `SearchType.playlist` is still requested — the main search
  /// screen omits it, because a playlist search returns mostly null entries to
  /// a Development Mode app. Here an empty result degrades to an empty grid,
  /// which is honest; there it would have been a permanently blank tab.
  Future<Paging<Playlist>> playlistsForMood(
    String moodQuery, {
    int limit = 12,
    CancelToken? cancelToken,
  }) => searchPlaylists(moodQuery, limit: limit, cancelToken: cancelToken);

  /// Suggestion strip under the search field.
  ///
  /// Spotify has no autocomplete endpoint, so suggestions are the names of
  /// the top artist and track hits for the partial query — real catalogue
  /// entries rather than invented strings.
  Future<List<String>> suggestions(
    String partial, {
    int limit = 6,
    CancelToken? cancelToken,
  }) async {
    if (partial.trim().length < 2) return const [];

    final results = await searchAll(
      partial,
      limit: limit,
      types: const [SearchType.artist, SearchType.track],
      cancelToken: cancelToken,
    );

    final seen = <String>{};
    final out = <String>[];
    for (final artist in results.artists.items) {
      if (seen.add(artist.name.toLowerCase())) out.add(artist.name);
    }
    for (final track in results.tracks.items) {
      if (out.length >= limit) break;
      if (seen.add(track.name.toLowerCase())) out.add(track.name);
    }
    return out.take(limit).toList(growable: false);
  }
}
