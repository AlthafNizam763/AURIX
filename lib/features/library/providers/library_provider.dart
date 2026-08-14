import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/preferences_store.dart';
import '../../../data/models/saved_item.dart';
import '../../../data/repositories/library_repository.dart';
import '../../auth/providers/auth_provider.dart';
import 'saved_tracks_provider.dart';

/// Library sections, shown as filter chips.
enum LibraryFilter {
  all('All'),
  playlists('Playlists'),
  albums('Albums'),
  artists('Artists'),
  liked('Liked Songs'),
  recent('Recently played');

  const LibraryFilter(this.label);
  final String label;
}

/// Sort orders. Alphabetical is by *display* name, not by the ID or the raw
/// string — "The Beatles" sorts under T, which is what the user sees.
enum LibrarySort {
  recentlyAdded('Recently added'),
  alphabetical('Alphabetical'),
  creator('Creator');

  const LibrarySort(this.label);
  final String label;
}

/// The library snapshot.
final librarySnapshotProvider =
    FutureProvider.autoDispose<LibrarySnapshot>((ref) async {
  final signedIn = ref.watch(isSignedInProvider);
  if (!signedIn) return const LibrarySnapshot();

  final link = ref.keepAlive();
  ref.onCancel(link.close);

  return ref.watch(libraryRepositoryProvider).load();
});

/// The active filter chip. Persisted so the Library tab reopens where the user
/// left it rather than resetting to "All" every time.
class LibraryFilterController extends Notifier<LibraryFilter> {
  late final PreferencesStore _prefs;

  @override
  LibraryFilter build() {
    _prefs = ref.watch(preferencesStoreProvider);
    final stored = _prefs.getString(PrefKeys.libraryFilter);
    return LibraryFilter.values
            .where((f) => f.name == stored)
            .firstOrNull ??
        LibraryFilter.all;
  }

  Future<void> set(LibraryFilter filter) async {
    state = filter;
    await _prefs.setString(PrefKeys.libraryFilter, filter.name);
  }
}

final libraryFilterProvider =
    NotifierProvider<LibraryFilterController, LibraryFilter>(
      LibraryFilterController.new,
    );

class LibrarySortController extends Notifier<LibrarySort> {
  late final PreferencesStore _prefs;

  @override
  LibrarySort build() {
    _prefs = ref.watch(preferencesStoreProvider);
    final stored = _prefs.getString(PrefKeys.librarySort);
    return LibrarySort.values.where((s) => s.name == stored).firstOrNull ??
        LibrarySort.recentlyAdded;
  }

  Future<void> set(LibrarySort sort) async {
    state = sort;
    await _prefs.setString(PrefKeys.librarySort, sort.name);
  }
}

final librarySortProvider =
    NotifierProvider<LibrarySortController, LibrarySort>(
      LibrarySortController.new,
    );

/// Search *within* the library — a local filter over already-loaded items, not
/// a Spotify request. Instant, works offline, and costs no quota.
final librarySearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Paged Liked Songs, for the dedicated screen.
///
/// Kept separate from [librarySnapshotProvider], which loads only the first 50
/// for the overview. A Liked Songs collection can run to thousands of tracks,
/// so this one pages on scroll.
class LikedSongsController extends AsyncNotifier<List<SavedTrack>> {
  static const int _pageSize = 50;

  bool _exhausted = false;
  bool _loading = false;

  bool get hasMore => !_exhausted;

  @override
  Future<List<SavedTrack>> build() async {
    // How a like or unlike made *anywhere* in the app reaches this screen.
    //
    // The listen is here, rather than the saved-track store pushing into this
    // provider, and the direction matters: `ref.read(likedSongsProvider)` would
    // *create* this provider if nothing had yet, so a heart tapped on the
    // player would have kicked off a Liked Songs network load for a screen the
    // user was not looking at. Listening from inside `build` means the
    // reconciliation exists only while this provider does.
    //
    // Invalidating on every toggle would also work and is worse: it re-requests
    // every page the user has scrolled through, and loses their scroll position
    // to show a change of one row.
    ref.listen<SavedTracksState>(savedTracksProvider, _reconcile);

    final page = await ref
        .watch(libraryRepositoryProvider)
        .moreLikedTracks(offset: 0, limit: _pageSize);
    // A short page means Spotify has no more to give.
    _exhausted = page.length < _pageSize;
    return page;
  }

  /// Adds or removes rows to match a like/unlike made elsewhere.
  void _reconcile(SavedTracksState? previous, SavedTracksState next) {
    final rows = state.value;
    if (rows == null) return;

    var updated = rows;

    for (final entry in next.known.entries) {
      if (previous?.known[entry.key] == entry.value) continue;

      final present = updated.any((s) => s.track.id == entry.key);

      if (!entry.value && present) {
        updated = updated
            .where((s) => s.track.id != entry.key)
            .toList(growable: false);
        continue;
      }

      if (entry.value && !present) {
        // Only a track the user actually toggled can be rebuilt into a row; a
        // plain `contains` lookup answering "true" carries no track object, and
        // that answer is about a row this list already has or has not paged to.
        final track = ref.read(savedTracksProvider.notifier).toggledTrack(entry.key);
        if (track == null) continue;
        updated = <SavedTrack>[
          // Newest first — the order Spotify returns, and the order this
          // screen's "Recently added" default sorts by.
          SavedTrack(track: track, addedAt: DateTime.now()),
          ...updated,
        ];
      }
    }

    if (identical(updated, rows)) return;
    state = AsyncData<List<SavedTrack>>(updated);
  }

  Future<void> loadMore() async {
    if (_loading || _exhausted) return;
    final current = state.value;
    if (current == null) return;

    _loading = true;
    try {
      final next = await ref
          .read(libraryRepositoryProvider)
          .moreLikedTracks(offset: current.length, limit: _pageSize);
      if (next.length < _pageSize) _exhausted = true;
      if (next.isEmpty) return;
      state = AsyncData<List<SavedTrack>>([...current, ...next]);
    } on Object {
      // Leave what is already loaded on screen; the next scroll retries.
    } finally {
      _loading = false;
    }
  }
}

final likedSongsProvider =
    AsyncNotifierProvider<LikedSongsController, List<SavedTrack>>(
      LikedSongsController.new,
    );
