import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/home_feed.dart';
import '../../../data/repositories/home_repository.dart';
import '../../auth/providers/auth_provider.dart';
import '../../library/providers/library_provider.dart';

/// The Home feed.
///
/// ## Why this is no longer a `FutureProvider`
///
/// It used to fetch: eight Spotify endpoints, a keep-alive with a timed expiry
/// so returning to the Home tab did not pay for all eight again, an
/// `onResume` to cancel that expiry, and a pull-to-refresh that invalidated the
/// whole thing.
///
/// Home reads the same three Firestore streams the Library screen watches, so
/// the feed is a *derivation* of state the app already holds rather than a
/// fetch of its own. That deletes the cache and its expiry window — there is
/// nothing to re-fetch — and it makes the page live: liking a song puts it on
/// the Liked shelf immediately, and creating a playlist puts it on the
/// playlists shelf, with nothing invalidating anything.
///
/// It still depends on `isSignedInProvider`, for the original reason: the feed
/// must be empty on sign-out rather than showing the previous account's
/// listening history to whoever signs in next.
final homeFeedProvider = Provider.autoDispose<AsyncValue<HomeFeed>>((ref) {
  final signedIn = ref.watch(isSignedInProvider);
  if (!signedIn) return const AsyncData(HomeFeed.empty);

  final library = ref.watch(librarySnapshotProvider);

  return library.whenData((snapshot) {
    final recentTracks = snapshot.recentlyPlayed
        .map((entry) => entry.track)
        .toList(growable: false);

    // Order is the page's editorial decision and lives here, in one list,
    // rather than being implied by the order of eight concurrent requests.
    // Empty shelves are dropped by `HomeFeed.visibleShelves`, so a new account
    // sees a short page rather than a page of placeholders.
    return HomeFeed(
      shelves: <HomeShelf>[
        HomeShelves.recentlyPlayed(recentTracks),
        HomeShelves.ownPlaylists(snapshot.playlists),
        HomeShelves.likedSongs(snapshot.likedTracks),
        HomeShelves.imported(snapshot.playlists),
      ],
      generatedAt: DateTime.now(),
    );
  });
});

/// Pull-to-refresh.
///
/// Firestore's snapshot listeners are already live, so there is nothing to
/// re-request — the gesture is kept because users expect it to work and its
/// absence reads as a broken screen, and because it is the natural way to ask
/// for a reconnect after being offline. Invalidating the streams makes them
/// re-subscribe, which is what forces that.
Future<void> refreshHome(WidgetRef ref) async {
  ref.invalidate(likedTracksProvider);
  ref.invalidate(userPlaylistsProvider);
  ref.invalidate(recentlyPlayedProvider);
  // Give the new subscriptions a frame to deliver their first snapshot, so the
  // spinner does not vanish before anything has visibly happened.
  await Future<void>.delayed(const Duration(milliseconds: 300));
}

/// The greeting, which changes through the day.
String greetingForNow([DateTime? now]) {
  final hour = (now ?? DateTime.now()).hour;
  if (hour < 5) return 'Good night';
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
}

final greetingProvider = Provider<String>((ref) => greetingForNow());
