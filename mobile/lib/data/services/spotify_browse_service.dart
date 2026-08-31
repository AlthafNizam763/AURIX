import 'package:dio/dio.dart';

import '../models/category.dart';
import '../models/playlist.dart';
import 'spotify_api_service.dart';
import 'spotify_search_service.dart';

/// Genre and mood browsing.
///
/// ## Why this class no longer calls `/browse/*`
///
/// Every browse endpoint is closed to a Development Mode application:
/// `/browse/categories` and `/browse/categories/{id}` were removed in February
/// 2026, and `/browse/categories/{id}/playlists` and
/// `/browse/featured-playlists` were restricted in November 2024. They do not
/// fail intermittently or for some accounts — they answer `403` to every
/// request this application will ever make.
///
/// So they are not called. Not tried-then-caught, not retried with a backoff:
/// removed. A request whose outcome is known is not worth a round trip, and
/// swallowing its `403` would still leave the latency and the log noise.
///
/// ## Where the data comes from instead
///
/// Genre tiles come from [MoodCatalogue.defaults] — a fixed list of *labels*,
/// each carrying a real Spotify search query. Tapping one runs `/search`, so
/// the playlists behind every tile are live Spotify data fetched at the moment
/// the user asks for them. The only local part is the name on the tile.
///
/// That distinction matters: nothing here fabricates Spotify content. It
/// substitutes a hardcoded *menu* for one Spotify will no longer serve, and
/// fills it from an endpoint that still works.
class SpotifyBrowseService extends SpotifyApiService {
  SpotifyBrowseService(super.dio, {SpotifySearchService? searchService})
    : _search = searchService ?? SpotifySearchService(dio);

  final SpotifySearchService _search;

  /// The genre and mood tiles.
  ///
  /// Synchronous in everything but signature — kept as a `Future` so callers
  /// and tests do not have to change, and so a future Spotify endpoint could
  /// be reinstated here without touching them.
  Future<List<Category>> categories({
    int limit = 20,
    String? locale,
    CancelToken? cancelToken,
  }) async {
    const all = MoodCatalogue.defaults;
    return all.length <= limit ? all : all.sublist(0, limit);
  }

  /// Playlists behind a genre tile, from a real Spotify search.
  Future<List<Playlist>> categoryPlaylists(
    Category category, {
    int limit = 12,
    CancelToken? cancelToken,
  }) async {
    final searched = await _search.playlistsForMood(
      category.query,
      limit: limit,
      cancelToken: cancelToken,
    );
    return searched.items;
  }
}
