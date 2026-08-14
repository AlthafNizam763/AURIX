import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../core/storage/preferences_store.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/saved_item.dart';
import '../../../data/models/track.dart';
import '../../auth/providers/auth_provider.dart';

/// Library sections, shown as filter chips.
///
/// Albums and Artists are gone. They were Spotify's `/me/albums` and
/// `/me/following` — a library of saved albums and followed artists that AURIX
/// does not keep, because AURIX's library is what the user put in it: playlists,
/// liked songs, and what they have played. Leaving the chips in place over an
/// empty list would have been the worse outcome.
enum LibraryFilter {
  all('All'),
  playlists('Playlists'),
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

/// Everything on the Library screen, in one object.
///
/// The shape survives from the Spotify implementation so the screens did not
/// have to be rewritten, but what fills it is entirely different: three
/// Firestore streams rather than five HTTP requests, and no cache layer,
/// because Firestore serves these from disk when the network is gone.
class LibrarySnapshot {
  const LibrarySnapshot({
    this.likedTracks = const [],
    this.playlists = const [],
    this.recentlyPlayed = const [],
  });

  final List<Track> likedTracks;
  final List<Playlist> playlists;
  final List<PlayHistoryEntry> recentlyPlayed;

  bool get isEmpty =>
      likedTracks.isEmpty && playlists.isEmpty && recentlyPlayed.isEmpty;

  /// Playlists the user built here, as opposed to imported ones.
  List<Playlist> get ownPlaylists =>
      playlists.where((p) => !p.source.isImported).toList(growable: false);

  List<Playlist> get importedPlaylists =>
      playlists.where((p) => p.source.isImported).toList(growable: false);
}

/// The user's playlists, live.
final userPlaylistsProvider = StreamProvider.autoDispose<List<Playlist>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream<List<Playlist>>.value(const []);
  return ref.watch(libraryRepositoryProvider).watchPlaylists(uid);
});

/// The user's liked tracks, live.
///
/// One stream for the whole app. The Liked Songs screen, the Home shelf, the
/// library count and every heart in every list read from here, which is what
/// makes a like tapped in the player appear on the playlist behind it with no
/// reconciliation code at all — the previous implementation needed about eighty
/// lines of it, and they are gone.
final likedTracksProvider = StreamProvider.autoDispose<List<Track>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream<List<Track>>.value(const []);

  // Kept alive across a screen closing, because this is the app's single
  // source of truth for "is this liked" and dropping it would make every
  // navigation re-read the collection.
  final link = ref.keepAlive();
  ref.onCancel(link.close);

  return ref.watch(libraryRepositoryProvider).watchLikedTracks(uid);
});

/// The set of liked track ids — what a heart actually asks.
///
/// Derived from [likedTracksProvider] rather than queried, so it costs nothing
/// and can never disagree with the list.
final likedTrackIdsProvider = Provider.autoDispose<Set<String>>((ref) {
  final tracks = ref.watch(likedTracksProvider).value;
  if (tracks == null) return const <String>{};
  return tracks.map((track) => track.id).toSet();
});

/// Whether one track is liked, as a rebuildable subscription.
///
/// A widget watching this rebuilds only when *its* track's answer changes, not
/// when any other heart in the app does.
final isTrackLikedProvider = Provider.autoDispose.family<bool, String>(
  (ref, id) => ref.watch(likedTrackIdsProvider).contains(id),
);

/// Play history, live.
final recentlyPlayedProvider =
    StreamProvider.autoDispose<List<PlayHistoryEntry>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream<List<PlayHistoryEntry>>.value(const []);
  return ref.watch(libraryRepositoryProvider).watchRecentlyPlayed(uid);
});

/// The three streams above, combined.
///
/// A [Provider] over three watched streams rather than a `FutureProvider` that
/// loads them: the screens want one object, and this way an update to any of
/// the three reaches the screen without a refetch. It reports loading only
/// while *all three* are still empty of data, so the page fills in as each
/// arrives rather than waiting for the slowest.
final librarySnapshotProvider = Provider.autoDispose<AsyncValue<LibrarySnapshot>>(
  (ref) {
    final signedIn = ref.watch(isSignedInProvider);
    if (!signedIn) return const AsyncData(LibrarySnapshot());

    final liked = ref.watch(likedTracksProvider);
    final playlists = ref.watch(userPlaylistsProvider);
    final recent = ref.watch(recentlyPlayedProvider);

    // An error anywhere is the whole library's error — unlike the Spotify
    // version, where one endpoint failing was routine and had to be survived.
    // A Firestore failure means the rules or the connection are wrong, and
    // showing two-thirds of a library while silently dropping the rest would
    // hide that.
    final error = liked.error ?? playlists.error ?? recent.error;
    if (error != null) {
      return AsyncError(
        error,
        liked.stackTrace ?? playlists.stackTrace ?? recent.stackTrace ??
            StackTrace.current,
      );
    }

    if (liked.value == null && playlists.value == null && recent.value == null) {
      return const AsyncLoading();
    }

    return AsyncData(
      LibrarySnapshot(
        likedTracks: liked.value ?? const [],
        playlists: playlists.value ?? const [],
        recentlyPlayed: recent.value ?? const [],
      ),
    );
  },
);

/// The active filter chip. Persisted so the Library tab reopens where the user
/// left it rather than resetting to "All" every time.
class LibraryFilterController extends Notifier<LibraryFilter> {
  late final PreferencesStore _prefs;

  @override
  LibraryFilter build() {
    _prefs = ref.watch(preferencesStoreProvider);
    final stored = _prefs.getString(PrefKeys.libraryFilter);
    // A stored value naming a filter this build no longer has — `albums` or
    // `artists` from a previous version — falls through to `all` rather than
    // leaving the screen on a chip that is not on it.
    return LibraryFilter.values.where((f) => f.name == stored).firstOrNull ??
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

final librarySortProvider = NotifierProvider<LibrarySortController, LibrarySort>(
  LibrarySortController.new,
);

/// Search *within* the library — a local filter over already-loaded items, not
/// a network request. Instant, and works offline.
final librarySearchProvider = StateProvider.autoDispose<String>((ref) => '');

/// Pull-to-refresh for the library screens.
///
/// The streams are already live, so this re-subscribes rather than re-fetching
/// — which is the useful thing to do after being offline, and which is what
/// users are reaching for when they pull. The short delay is what stops the
/// spinner vanishing on the same frame it appeared, before anything has
/// visibly happened.
Future<void> refreshLibrary(WidgetRef ref) async {
  ref.invalidate(likedTracksProvider);
  ref.invalidate(userPlaylistsProvider);
  ref.invalidate(recentlyPlayedProvider);
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// Liked Songs for its dedicated screen.
///
/// A plain alias of [likedTracksProvider] rather than a paged controller of its
/// own, and the deletion behind that alias is the point of this whole phase.
///
/// The Spotify implementation could not simply read the collection: liked songs
/// lived behind `/me/tracks`, which pages at 50, so this screen had a paging
/// controller, an exhaustion flag, an in-flight guard, and — because the paged
/// list and the app's heart state were two separate sources of truth — a
/// reconciliation routine that added and removed rows to match likes made on
/// other screens. All of it existed to compensate for the library being
/// somewhere else.
///
/// The library is a Firestore collection now. Watching it *is* the feature.
final likedSongsProvider = likedTracksProvider;
