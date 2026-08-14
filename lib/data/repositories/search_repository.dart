import '../../core/constants/app_constants.dart';
import '../../core/storage/preferences_store.dart';
import '../models/category.dart';
import '../models/search_results.dart';
import '../search/search_provider.dart';

/// Search, plus the local history behind it.
///
/// ## What changed
///
/// This used to hold a `SpotifySearchService` and call `GET /v1/search`
/// directly, with a `CancelToken` to stop a slow response for "bea" landing
/// after the response for "beatles". Both are gone: it holds a [SearchService]
/// now, which fans a query out across every available [SearchProvider], and the
/// race is handled where it belongs — in the search *controller*, which knows
/// which query is current and discards answers to older ones.
///
/// Recent searches are stored on-device only. They are the user's queries, not
/// anyone's data to collect, and there is no reason to send them anywhere.
class SearchRepository {
  SearchRepository({
    required SearchService searchService,
    required PreferencesStore preferences,
  }) : _search = searchService,
       _prefs = preferences;

  final SearchService _search;
  final PreferencesStore _prefs;

  Future<SearchResults> search(
    String query, {
    int limit = AppConstants.maxSearchPageSize,
  }) {
    // Never spend a round trip on a blank query. The debounced field emits one
    // every time the user clears the box.
    if (query.trim().isEmpty) return Future.value(SearchResults.empty);
    return _search.search(query, limit: limit);
  }

  /// Loads another page for one result tab.
  ///
  /// Returns nothing. Paging was a property of Spotify's search endpoint, which
  /// returned 20 at a time; a fan-out across providers has no single offset to
  /// advance. The screen's "load more" affordance is hidden accordingly rather
  /// than left calling a method that returns an empty page forever.
  Future<SearchResults> loadMore(
    String query,
    SearchType type, {
    required int offset,
    int limit = AppConstants.maxSearchPageSize,
  }) => Future.value(SearchResults.empty);

  /// True when anything could be paged. Always false today — see [loadMore].
  bool get supportsPaging => false;

  Future<List<String>> suggestions(String partial) async => const [];

  /// Kept as a no-op so callers that tidy up on dispose need no change.
  ///
  /// There is no in-flight HTTP request to cancel: the library provider is
  /// synchronous over in-memory state, and a provider that does make a request
  /// is responsible for its own lifetime.
  void cancelInFlight() {}

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
