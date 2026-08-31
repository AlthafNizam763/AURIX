import 'dart:async';

import '../models/search_results.dart';

/// Somewhere AURIX can search.
///
/// ## Why this is an interface
///
/// Search used to be `GET /v1/search` and nothing else, so `SearchRepository`
/// held a `SpotifySearchService` and the question "what happens when Spotify is
/// not available?" had no answer other than "search stops working". The library
/// is AURIX's own now, and the useful default is to search *that* — a user
/// looking for a song they have almost always means one they already have.
///
/// So search is a list of providers, tried together, results merged. Adding a
/// catalogue later — a licensed one, or a second import source — means writing
/// one class and adding it to the list.
///
/// ## The ordering rule
///
/// [priority] decides whose results come first when two providers both match.
/// The library outranks any catalogue, deliberately: a user who searches for a
/// song in their own playlists should find their copy, which is playable and
/// which they can add to a playlist, rather than a catalogue entry that looks
/// identical and is not in their library.
abstract interface class SearchProvider {
  /// Shown as the section heading when results are grouped by provider.
  String get displayName;

  /// Lower sorts first. The library is 0; catalogues are 100 and up.
  int get priority;

  /// False when this provider cannot serve a query right now — no credentials,
  /// no session, no network. A false here removes the provider from the run
  /// rather than failing it.
  bool get isAvailable;

  /// Runs a query.
  ///
  /// Must not throw for an ordinary failure: return [SearchResults.empty]
  /// instead. One provider being unreachable must not empty a results page
  /// that another provider could have filled — see [SearchService.search].
  Future<SearchResults> search(String query, {int limit = 20});
}

/// Runs a query across every available [SearchProvider] and merges the results.
///
/// Providers run concurrently and independently. A provider that throws is
/// logged and dropped, which is the property that matters: the AURIX library
/// provider works offline and needs no credentials, so a results page always
/// has at least one source that can answer.
class SearchService {
  SearchService({required List<SearchProvider> providers})
      : _providers = _sorted(providers);

  static List<SearchProvider> _sorted(List<SearchProvider> providers) {
    final ordered = <SearchProvider>[...providers]
      ..sort((a, b) => a.priority.compareTo(b.priority));
    return List<SearchProvider>.unmodifiable(ordered);
  }

  final List<SearchProvider> _providers;

  List<SearchProvider> get availableProviders =>
      _providers.where((provider) => provider.isAvailable).toList();

  Future<SearchResults> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return SearchResults.empty;

    final active = availableProviders;
    if (active.isEmpty) return SearchResults.empty;

    final results = await Future.wait<SearchResults>(
      active.map((provider) async {
        try {
          return await provider.search(trimmed, limit: limit);
        } on Object {
          // Belt and braces over the contract above: a provider that breaks
          // its promise not to throw still must not empty the page.
          return SearchResults.empty;
        }
      }),
    );

    // Merged in provider priority order, which the constructor has already
    // sorted the list into.
    var merged = SearchResults.empty;
    for (final result in results) {
      merged = merged.merge(result);
    }
    return merged;
  }
}
