import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../playback/player_controller.dart';
import 'mini_player.dart';

/// Mounts the mini player above every route in the app.
///
/// ## Why it is not in the shell
///
/// It was, and that was the bug. `AppShell` renders the tab bar and used to
/// render the mini player above it — but AURIX's detail routes (album, artist,
/// playlist, category, settings, Liked Songs) are declared with
/// `parentNavigatorKey: _rootNavigatorKey`, so they push onto the **root**
/// navigator and cover the shell completely. Anything the shell drew went with
/// it. Navigating from Home to Liked Songs while music played made the bar
/// disappear even though playback never stopped.
///
/// Installed from `MaterialApp`'s builder instead, this sits outside the
/// `Navigator` entirely, so no route can cover it and no route disposal can
/// unmount it. The playback state it renders is app-scoped Riverpod state and
/// was never the thing being lost.
///
/// ## The one thing it has to know about routes
///
/// How far off the bottom to sit. On a shell tab the navigation bar is below
/// it; on a pushed route there is no navigation bar and the player should drop
/// to the safe area. That offset is animated, so the bar slides rather than
/// jumping as a route pushes over the shell.
class GlobalMiniPlayer extends ConsumerWidget {
  const GlobalMiniPlayer({required this.child, super.key});

  final Widget child;

  /// Paths that render inside [AppShell], and therefore have a bottom
  /// navigation bar underneath the mini player.
  static const Set<String> shellPaths = <String>{
    Routes.home,
    Routes.search,
    Routes.library,
    Routes.playlists,
    Routes.profile,
  };

  /// Routes that are the now-playing surface themselves. A mini player over the
  /// full player would be a second copy of the same controls.
  static const Set<String> suppressingPaths = <String>{
    Routes.player,
    Routes.queue,
    Routes.devices,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTrack = ref.watch(hasActivePlaybackProvider);
    final router = ref.watch(routerProvider);

    return Stack(
      children: <Widget>[
        child,
        // Route changes arrive through the delegate's own `Listenable` — the
        // one `Router` itself listens to — rather than through provider state
        // that would have to be kept in step with navigation by hand.
        ListenableBuilder(
          listenable: router.routerDelegate,
          builder: (context, _) {
            final path = currentTopLocation(router);
            final visible = hasTrack && !suppressingPaths.contains(path);
            final safeBottom = MediaQuery.paddingOf(context).bottom;
            final bottom = shellPaths.contains(path)
                ? safeBottom + AppSizes.bottomNavHeight + AppSpacing.xs
                : safeBottom + AppSpacing.sm;

            return AnimatedPositioned(
              duration: AppConstants.medium,
              curve: Curves.easeOutCubic,
              left: 0,
              right: 0,
              // Parked just off the bottom edge when there is nothing to show,
              // so it slides away rather than blinking out.
              bottom: visible
                  ? bottom
                  : -(AppSizes.miniPlayerHeight + safeBottom + AppSpacing.xl),
              child: AnimatedOpacity(
                duration: AppConstants.medium,
                opacity: visible ? 1 : 0,
                // An invisible bar must not keep eating taps on its way out.
                child: IgnorePointer(
                  ignoring: !visible,
                  // Outside the `Navigator` there is no `Material`, and the bar
                  // needs one: `IconButton` asserts on it, and without the
                  // `DefaultTextStyle` it carries, every label renders with
                  // Flutter's yellow unstyled-text underline — which an
                  // explicit `TextStyle` does not clear, because `merge` keeps
                  // the inherited decoration. `transparency` paints nothing.
                  child: const Material(
                    type: MaterialType.transparency,
                    child: MiniPlayer(),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
