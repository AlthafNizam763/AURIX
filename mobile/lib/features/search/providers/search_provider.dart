import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_mapper.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/debouncer.dart';
import '../../../data/models/search_results.dart';
import '../../../data/repositories/search_repository.dart';

enum SearchPhase { idle, typing, loading, results, empty, error }

class SearchState extends Equatable {
  const SearchState({
    this.query = '',
    this.phase = SearchPhase.idle,
    this.results = SearchResults.empty,
    this.activeFilter,
    this.suggestions = const [],
    this.recentSearches = const [],
    this.error,
    this.isLoadingMore = false,
  });

  final String query;
  final SearchPhase phase;
  final SearchResults results;

  /// Null means "All" — the mixed overview with a section per type.
  final SearchType? activeFilter;

  final List<String> suggestions;
  final List<String> recentSearches;
  final ApiException? error;
  final bool isLoadingMore;

  bool get hasQuery => query.trim().isNotEmpty;
  bool get showHistory => !hasQuery;

  SearchState copyWith({
    String? query,
    SearchPhase? phase,
    SearchResults? results,
    SearchType? activeFilter,
    List<String>? suggestions,
    List<String>? recentSearches,
    ApiException? error,
    bool? isLoadingMore,
    bool clearFilter = false,
    bool clearError = false,
  }) => SearchState(
    query: query ?? this.query,
    phase: phase ?? this.phase,
    results: results ?? this.results,
    activeFilter: clearFilter ? null : (activeFilter ?? this.activeFilter),
    suggestions: suggestions ?? this.suggestions,
    recentSearches: recentSearches ?? this.recentSearches,
    error: clearError ? null : (error ?? this.error),
    isLoadingMore: isLoadingMore ?? this.isLoadingMore,
  );

  @override
  List<Object?> get props => [
    query,
    phase,
    results,
    activeFilter,
    suggestions,
    recentSearches,
    error,
    isLoadingMore,
  ];
}

/// Search state.
///
/// Two mechanisms keep this responsive and correct:
///
///  * **Debounce** — a request fires 350ms after the last keystroke, not on
///    every one. Without it, typing "beatles" is seven Spotify requests and a
///    fast track to a 429.
///  * **Generation counter** — every search increments a token, and a response
///    is only applied if its token is still current. The repository also
///    cancels the in-flight Dio request, but cancellation is best-effort;
///    the counter is what actually guarantees "bea" cannot overwrite
///    "beatles".
/// Named `SearchQueryController` rather than `SearchController` because
/// Material exports a class by that name; the collision would force every
/// screen importing both to alias one of them.
class SearchQueryController extends Notifier<SearchState> {
  late final SearchRepository _repository;
  final Debouncer _debouncer = Debouncer(delay: AppConstants.searchDebounce);
  int _generation = 0;

  @override
  SearchState build() {
    _repository = ref.watch(searchRepositoryProvider);
    ref.onDispose(() {
      _debouncer.dispose();
      _repository.cancelInFlight();
    });
    return SearchState(recentSearches: _repository.recentSearches());
  }

  void onQueryChanged(String raw) {
    final query = raw.trim();

    if (query.isEmpty) {
      _debouncer.cancel();
      _generation++;
      _repository.cancelInFlight();
      state = state.copyWith(
        query: '',
        phase: SearchPhase.idle,
        results: SearchResults.empty,
        suggestions: const [],
        recentSearches: _repository.recentSearches(),
        clearError: true,
        clearFilter: true,
      );
      return;
    }

    state = state.copyWith(query: query, phase: SearchPhase.typing, clearError: true);
    _debouncer.run(() => unawaited(_run(query)));
  }

  /// Runs immediately — the user pressed the keyboard's search key or picked a
  /// suggestion, and should not be made to wait out the debounce.
  Future<void> submit(String raw) async {
    final query = raw.trim();
    if (query.isEmpty) return;
    _debouncer.cancel();
    state = state.copyWith(query: query);
    await _run(query, persistHistory: true);
  }

  Future<void> _run(String query, {bool persistHistory = false}) async {
    final generation = ++_generation;
    state = state.copyWith(phase: SearchPhase.loading, clearError: true);

    try {
      final results = await _repository.search(query);
      if (generation != _generation) return;

      final history = persistHistory
          ? await _repository.addRecentSearch(query)
          : state.recentSearches;

      state = state.copyWith(
        results: results,
        recentSearches: history,
        phase: results.isEmpty ? SearchPhase.empty : SearchPhase.results,
      );
    } on ApiException catch (error) {
      if (generation != _generation) return;
      // A cancelled request is not a failure — a newer search replaced it.
      if (error.kind == ApiFailureKind.cancelled) return;
      state = state.copyWith(phase: SearchPhase.error, error: error);
    } on Object catch (error) {
      if (generation != _generation) return;
      state = state.copyWith(
        phase: SearchPhase.error,
        error: ErrorMapper.fromUnknown(error),
      );
    }
  }

  void setFilter(SearchType? filter) {
    state = state.copyWith(
      activeFilter: filter,
      clearFilter: filter == null,
    );
  }

  /// Loads the next page of the active tab.
  Future<void> loadMore() async {
    final filter = state.activeFilter;
    // Paging only applies to a single-type tab; the "All" overview shows the
    // top handful of each and paging it would be meaningless.
    if (filter == null || state.isLoadingMore || !state.hasQuery) return;

    final current = state.results.pageFor(filter);
    if (!current.hasMore) return;

    state = state.copyWith(isLoadingMore: true);
    final generation = _generation;

    try {
      final page = await _repository.loadMore(
        state.query,
        filter,
        offset: current.items.length,
      );
      if (generation != _generation) return;
      state = state.copyWith(
        results: state.results.appendPage(filter, page),
        isLoadingMore: false,
      );
    } on Object {
      if (generation != _generation) return;
      // A failed "load more" leaves the existing results intact; retrying is
      // one more scroll away.
      state = state.copyWith(isLoadingMore: false);
    }
  }

  Future<void> removeRecent(String query) async {
    final updated = await _repository.removeRecentSearch(query);
    state = state.copyWith(recentSearches: updated);
  }

  Future<void> clearRecents() async {
    await _repository.clearRecentSearches();
    state = state.copyWith(recentSearches: const []);
  }

  void clear() => onQueryChanged('');

  List<String> popularSearches() => _repository.popularSearches();
}

final searchControllerProvider =
    NotifierProvider<SearchQueryController, SearchState>(
      SearchQueryController.new,
    );
