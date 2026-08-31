import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants/app_constants.dart';
import 'core/providers/app_providers.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'features/dynamic_island/dynamic_island.dart';
import 'features/dynamic_island/providers/dynamic_island_controller.dart';
import 'features/settings/providers/settings_provider.dart';
import 'features/shell/widgets/global_mini_player.dart';
import 'playback/media_notification_taps.dart';

/// The application root.
///
/// Kept separate from `main.dart` so widget tests can mount the real app with
/// overridden providers, without going through `bootstrap()` and its platform
/// channels.
class AurixApp extends ConsumerWidget {
  const AurixApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final themeMode = ref.watch(settingsProvider.select((s) => s.themeMode));
    final reduceMotion = ref.watch(reduceMotionProvider);

    // The configured appearance. Watched as a whole rather than through
    // `select` because every field of it feeds the two `ThemeData` objects
    // below — there is no narrower subscription to make.
    //
    // `fontFamily` is the *resolved* family, which is not always the configured
    // one: while a custom font is downloading it is the previous face, and this
    // rebuilds once when the real one is registered. See `FontRegistry`.
    final theme = ref.watch(themeControllerProvider);

    // Brings the island's background half into existence and keeps it there.
    //
    // `listen` with an empty callback rather than `watch`: the controller's
    // state changes when AURIX is backgrounded and when the floating surface
    // goes up, and watching it here would rebuild `MaterialApp.router` — the
    // whole app — on both. Listening subscribes without rebuilding, which is
    // all this needs: the controller does its work from inside itself, and
    // nothing in this build method reads its state.
    //
    // It must be mounted here rather than inside [DynamicIslandLayer] because
    // that layer hands the app straight back when the island is switched off,
    // and the controller is what notices the switch being turned on.
    ref.listen(dynamicIslandControllerProvider, (_, _) {});

    // Keeps the media notification's presentation in step with the configured
    // "outside player" variant. Listened to rather than watched because
    // nothing here renders from it — the OS draws that surface, and this only
    // tells it what to draw.
    ref.listen(outsidePlayerSyncProvider, (_, _) {});

    // Brings the notification-tap listener into existence, for the same reason
    // and by the same means: it has to be subscribed before the tap that opened
    // the app is delivered, and no screen is a safe place to own that — the tap
    // arrives while AURIX may have no screen mounted at all.
    ref.listen(mediaNotificationTapsProvider, (_, _) {});

    // Resolved here rather than read off the theme, because under
    // `ThemeMode.system` the answer lives in the platform and not in
    // `themeMode`. Getting this wrong paints black status-bar icons on a black
    // status bar, which looks like the app failed to draw its header.
    final brightness = switch (themeMode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };

    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Derived from the configured background rather than from the nominal
      // brightness, so a pale "dark" theme still gets dark status-bar icons
      // instead of white-on-white.
      value: AppTheme.overlayFrom(theme.config, brightness),
      child: MaterialApp.router(
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        routerConfig: router,
        // Both colourways are built from the same configuration document, so a
        // user switching their phone to light mode gets the operator's light
        // palette rather than the shipped one.
        theme: AppTheme.from(
          theme.config,
          Brightness.light,
          fontFamily: theme.fontFamily,
        ),
        darkTheme: AppTheme.from(
          theme.config,
          Brightness.dark,
          fontFamily: theme.fontFamily,
        ),
        themeMode: themeMode,
        builder: (context, child) {
          if (child == null) return const SizedBox.shrink();

          final media = MediaQuery.of(context);

          return MediaQuery(
            data: media.copyWith(
              // Cap text scaling. Beyond 1.3 the mini player and bottom nav
              // start clipping, and the fix is a genuinely different layout
              // rather than more scaling.
              textScaler: media.textScaler.clamp(
                minScaleFactor: 0.85,
                maxScaleFactor: 1.3,
              ),
              // Honour the in-app "reduce motion" setting as well as the OS
              // one, so a single check covers both everywhere in the tree.
              disableAnimations: media.disableAnimations || reduceMotion,
            ),
            // Both layers sit outside the router's Navigator, so they float
            // over every route — tabs, pushed detail screens and modals alike
            // — and are never unmounted by navigation. Inside the MediaQuery
            // above, so they inherit the clamped text scale and the
            // reduce-motion flag like everything else.
            //
            // Order matters: the mini player is nearer the child, so the
            // island draws over it if they ever meet.
            child: DynamicIslandLayer(
              child: GlobalMiniPlayer(child: child),
            ),
          );
        },
      ),
    );
  }
}
