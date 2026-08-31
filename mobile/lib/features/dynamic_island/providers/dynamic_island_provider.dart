import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/route_names.dart';
import '../../../playback/player_controller.dart';
import '../../auth/providers/auth_provider.dart';
import '../../settings/providers/settings_provider.dart';

/// Whether the user has the island switched on.
///
/// Governs both halves of the feature: the in-app pill this file gates, and the
/// floating surface [DynamicIslandController] puts up once AURIX is
/// backgrounded. Leaving the app is a *second*, separate consent on top of this
/// one — see `AppSettings.dynamicIslandOverlay` — because a widget inside the
/// user's own app and a window drawn over every other app are not the same
/// permission to ask for.
final dynamicIslandEnabledProvider = Provider<bool>(
  (ref) => ref.watch(settingsProvider.select((s) => s.dynamicIsland)),
);

/// Whether the *in-app* island belongs on screen at all right now.
///
/// Says nothing about the floating surface, which has its own conditions and
/// its own controller: this one is about a widget in AURIX's tree, and that
/// tree is not drawn at all once the app is backgrounded.
///
/// Deliberately *not* the whole answer: which route is showing also decides,
/// and that lives with the router rather than in provider state — see
/// [islandSuppressingRoutes] and `DynamicIslandLayer`.
///
/// Gating on sign-in matters because AURIX restores the last played track on
/// launch, so a track can exist while the splash or login screen is up. Those
/// screens are their own composition and an island floating over them would be
/// the app talking over itself.
final dynamicIslandActiveProvider = Provider<bool>((ref) {
  if (!ref.watch(dynamicIslandEnabledProvider)) return false;
  if (!ref.watch(isSignedInProvider)) return false;
  return ref.watch(hasActivePlaybackProvider);
});

/// Routes that already own the now-playing surface.
///
/// The island is a shortcut *to* the player; drawing it on top of the player
/// would put two sets of transport controls on one screen and land the pill
/// squarely on that screen's own header.
const Set<String> islandSuppressingRoutes = <String>{
  Routes.player,
  Routes.queue,
  Routes.devices,
};
