import 'dart:async';

import '../../core/config/env.dart';
import '../../core/utils/app_logger.dart';
import '../models/search_results.dart';
import '../services/spotify_auth_service.dart';
import '../services/spotify_search_service.dart';
import 'search_provider.dart';

/// Searches the Spotify catalogue, when there is a Spotify session to do it
/// with.
///
/// ## Why it is conditional
///
/// Search used to *be* this — `GET /v1/search`, the only source, called
/// unconditionally, because the app was signed in to Spotify by definition.
/// AURIX signs in to Firebase now, and a user who has never imported anything
/// has no Spotify session at all. [isAvailable] is what makes that a normal
/// state rather than a broken search screen: the provider drops out of the run
/// and `LibrarySearchProvider` answers alone.
///
/// It becomes available for as long as an import session is live, which is a
/// genuinely useful window — the user who has just connected Spotify is exactly
/// the one who benefits from catalogue results.
class SpotifySearchProvider implements SearchProvider {
  SpotifySearchProvider({
    required SpotifyAuthService authService,
    required SpotifySearchService searchService,
  }) : _auth = authService,
       _search = searchService;

  final SpotifyAuthService _auth;
  final SpotifySearchService _search;

  @override
  String get displayName => 'Spotify';

  /// 100: below the library, above any future catalogue that is less
  /// authoritative about what the user can actually play.
  @override
  int get priority => 100;

  @override
  bool get isAvailable => Env.isSpotifyConfigured && _auth.isAuthenticated;

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    if (!isAvailable) return SearchResults.empty;
    try {
      return await _search.searchAll(query, limit: limit);
    } on Object catch (error) {
      // Contractually must not throw — see [SearchProvider.search]. A Spotify
      // failure costs its section of the results and nothing else.
      AppLogger.debug('Spotify search failed: $error', scope: 'search');
      return SearchResults.empty;
    }
  }
}
