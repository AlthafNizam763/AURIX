import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/storage/preferences_store.dart';
import '../models/category.dart';
import '../models/search_results.dart';
import '../services/spotify_search_service.dart';

/// Search, plus the local history behind it.
///
/// Recent searches are stored on-device only. They are the user's queries, not
/// Spotify's data, and there is no reason to send them anywhere.
class SearchRepository {
  SearchRepository({
    required SpotifySearchService searchService,
    required PreferencesStore preferences,
  }) : _search = searchService,
       _prefs = preferences;

  final SpotifySearchService _search;
  final PreferencesStore _prefs;

  /// The in-flight request, cancelled when a newer query supersedes it.
  ///
  /// Without this, a slow response for "bea" can land after the response for
  /// "beatles" and overwrite the correct results — the classic search race.
  CancelToken? _inFlight;

  Future<SearchResults> search(
    String query, {
    int limit = AppConstants.maxSearchPageSize,
  }) async {
    // Never spend a cancellation, a token or a round trip on a blank query.
    // The debounced field emits one every time the user clears the box.
    if (query.trim().isEmpty) return SearchResults.empty;

    _inFlight?.cancel('superseded');
    final token = CancelToken();
    _inFlight = token;

    try {
      return await _search.searchAll(query, limit: limit, cancelToken: token);
    } finally {
      if (identical(_inFlight, token)) _inFlight = null;
    }
  }

  /// Loads another page for one result tab.
  Future<SearchResults> loadMore(
    String query,
    SearchType type, {
    required int offset,
    int limit = AppConstants.maxSearchPageSize,
  }) {
    if (query.trim().isEmpty) return Future.value(SearchResults.empty);
    return _search.searchType(query, type, limit: limit, offset: offset);
  }

  Future<List<String>> suggestions(String partial) async {
    try {
      return await _search.suggestions(partial);
    } on Object {
      // Suggestions are a nicety; never surface a failure for them.
      return const [];
    }
  }

  void cancelInFlight() {
    _inFlight?.cancel('cancelled');
    _inFlight = null;
  }

  // ---- Recent searches ---------------------------------------------------

  List<String> recentSearches() => _prefs.getStringList(PrefKeys.recentSearches);

  Future<List<String>> addRecentSearch(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return recentSearches();

    final existing = recentSearches();
    // Case-insensitive de-duplication, most recent first.
    final updated = <String>[
      trimmed,
      ...existing.where((q) => q.toLowerCase() != trimmed.toLowerCase()),
    ].take(AppConstants.maxRecentSearches).toList();

    await _prefs.setStringList(PrefKeys.recentSearches, updated);
    return updated;
  }

  Future<List<String>> removeRecentSearch(String query) async {
    final updated = recentSearches()
        .where((q) => q.toLowerCase() != query.toLowerCase())
        .toList();
    await _prefs.setStringList(PrefKeys.recentSearches, updated);
    return updated;
  }

  Future<void> clearRecentSearches() =>
      _prefs.setStringList(PrefKeys.recentSearches, const []);

  /// Shown before the user has typed anything and has no history.
  List<String> popularSearches() => MoodCatalogue.popularSearches;
}
