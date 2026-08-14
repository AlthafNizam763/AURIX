import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/providers/app_providers.dart';
import '../../../data/models/home_feed.dart';
import '../../auth/providers/auth_provider.dart';

/// The Home feed.
///
/// Depends on `isSignedInProvider` so the feed is discarded on sign-out —
/// otherwise the previous account's listening history would still be on screen
/// after switching users.
final homeFeedProvider = FutureProvider.autoDispose<HomeFeed>((ref) async {
  final signedIn = ref.watch(isSignedInProvider);
  if (!signedIn) return HomeFeed.empty;

  // Keep the feed alive across quick tab switches so returning to Home does
  // not refetch eight endpoints. It is dropped when the user leaves for good.
  //
  // The window is what makes that true. This used to be `ref.onCancel(
  // link.close)`, which closes the link the instant the last listener goes —
  // so the keep-alive expired at exactly the moment it was needed and every
  // return to Home paid for eight requests again. Closing on a timer is the
  // difference between a cache and a comment claiming there is one.
  final link = ref.keepAlive();
  Timer? expiry;
  ref.onDispose(() => expiry?.cancel());
  ref.onCancel(() {
    expiry?.cancel();
    expiry = Timer(AppConstants.homeCacheTtl, link.close);
  });
  // Coming back inside the window cancels the eviction rather than restarting
  // the fetch.
  ref.onResume(() {
    expiry?.cancel();
    expiry = null;
  });

  return ref.watch(homeRepositoryProvider).load();
});

/// Pull-to-refresh.
///
/// Invalidating rather than calling `load(forceRefresh: true)` directly keeps
/// one code path for the fetch, and gives the UI the loading state for free.
/// Awaiting the new future is what holds the refresh spinner open until the
/// data actually lands.
Future<void> refreshHome(WidgetRef ref) async {
  ref.invalidate(homeFeedProvider);
  await ref.read(homeFeedProvider.future);
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
