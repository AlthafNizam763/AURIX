import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers/app_providers.dart';
import '../../core/router/navigation.dart';
import '../../core/theme/app_dimens.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/state_views.dart';
import 'widgets/app_bottom_navigation.dart';

/// The persistent frame around the three tabs.
///
/// [StatefulNavigationShell] gives each tab its own `Navigator`, so switching
/// tabs preserves scroll position and back-stack — the Home feed does not
/// rebuild every time the user checks Search.
///
/// The mini player and navigation bar sit *outside* that shell, which is what
/// makes them survive tab switches and detail pushes.
class AppShell extends ConsumerWidget {
  const AppShell({required this.navigationShell, super.key});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOffline = ref.watch(isOfflineProvider);
    final atHome = navigationShell.currentIndex == homeBranchIndex;

    // Android's back button, and the gesture that replaced it, both arrive
    // here — as one `popRoute`, which is why there is a single handler rather
    // than a button listener and a gesture listener.
    //
    // Only the shell's own back press reaches this. Every detail screen in
    // AURIX pushes onto the *root* navigator, so it sits above the shell and
    // pops itself first; by the time this runs, the tabs are what is showing.
    //
    // `PopScope`, not `WillPopScope`: the predictive-back gesture needs to know
    // whether the pop will be allowed *before* the user commits to it, which is
    // what `canPop` answers and what the old callback could not.
    return PopScope(
      // On Home there is nothing left to unwind, and letting the pop through is
      // what closes the app — the expected end of a back journey on Android,
      // and deliberately not a bounce to splash or login.
      canPop: atHome,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Anywhere else, back means "up to the root destination" rather than
        // "quit". Search → back → Home, then back again → closed. `goBranch`
        // switches to the existing Home branch instead of pushing a second
        // copy of it, so this cannot grow the stack however often it runs.
        navigationShell.goBranch(homeBranchIndex);
      },
      child: _scaffold(context, ref, isOffline: isOffline),
    );
  }

  Widget _scaffold(
    BuildContext context,
    WidgetRef ref, {
    required bool isOffline,
  }) {
    return Scaffold(
      // The body extends behind the bar so content scrolls under the gradient
      // scrim rather than stopping at a hard line.
      extendBody: true,
      body: Column(
        children: [
          if (isOffline)
            OfflineBanner(
              onRetry: () => ref.read(connectivityServiceProvider).refresh(),
            ),
          Expanded(child: navigationShell),
        ],
      ),
      // The mini player is deliberately *not* here. It is mounted above the
      // router by `GlobalMiniPlayer`, because every detail route in AURIX
      // pushes onto the root navigator and covers this shell — which took the
      // mini player with it and made the bar vanish on Liked Songs. The space
      // for it is still reserved by `shellBottomInset`.
      bottomNavigationBar: AppBottomNavigation(
        currentIndex: navigationShell.currentIndex,
        onDestinationSelected: (index) => _onTabSelected(context, index),
      ),
    );
  }

  void _onTabSelected(BuildContext context, int index) {
    // Tapping the active tab pops that branch to its root — the standard
    // "get me back to the top" gesture.
    navigationShell.goBranch(
      index,
      initialLocation: index == navigationShell.currentIndex,
    );
  }
}

/// Total height the shell occupies at the bottom of the screen.
///
/// Scrollable pages add this as bottom padding so their last row is not hidden
/// behind the mini player — the classic "can't reach the final track" bug.
double shellBottomInset(BuildContext context, {required bool hasTrack}) {
  final safeArea = MediaQuery.paddingOf(context).bottom;
  return AppSizes.bottomNavHeight +
      safeArea +
      (hasTrack ? AppSizes.miniPlayerHeight + AppSpacing.md : 0);
}

/// Convenience for pages inside the shell.
class ShellAwarePadding extends ConsumerWidget {
  const ShellAwarePadding({required this.child, this.extra = 0, super.key});

  final Widget child;
  final double extra;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(hasActivePlaybackProvider);
    return Padding(
      padding: EdgeInsets.only(
        bottom: shellBottomInset(context, hasTrack: hasTrack) + extra,
      ),
      child: child,
    );
  }
}
