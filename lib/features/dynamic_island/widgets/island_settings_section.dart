import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../playback/background_island_channel.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../../settings/providers/settings_provider.dart';
import '../../settings/widgets/settings_widgets.dart';
import '../providers/dynamic_island_controller.dart';

/// The Dynamic Island block in Settings: the feature switch, the separate
/// outside-the-app consent, and the honest note about what each one does.
///
/// ## Why the second row exists
///
/// The island is two different things wearing one name. Inside AURIX it is a
/// widget — a decoration in the user's own app, costing nothing but pixels.
/// Outside AURIX it is a window drawn over every other app on the phone, which
/// Android gates behind `SYSTEM_ALERT_WINDOW` precisely because that is a
/// capability worth thinking about before granting.
///
/// Folding the two into one switch would mean flicking a visual preference
/// silently opened a system permission screen. So the switch stays what it was,
/// and the outside-the-app part is its own row, its own preference, and its own
/// explanation — shown only once the island is on, and never requesting
/// anything until the user taps it.
///
/// ## What it never claims
///
/// The row's copy is generated from what the *platform* reported, not from
/// `Platform.isAndroid`. On a build with no floating surface it says so and
/// offers no switch, rather than presenting a control that would turn on
/// something that never appears.
class DynamicIslandSettingsSection extends ConsumerWidget {
  const DynamicIslandSettingsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final capability = ref.watch(islandCapabilityProvider);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SettingsBrandSwitch(
          icon: AurixGlyph.phone,
          title: 'Dynamic Island',
          subtitle: settings.dynamicIsland
              ? 'Floating music control at the top while something plays'
              : 'Off — the mini player handles playback controls',
          value: settings.dynamicIsland,
          onChanged: controller.setDynamicIsland,
        ),

        // Only meaningful once the island itself is on, and only on a platform
        // that has somewhere to put it.
        if (settings.dynamicIsland && capability.exists)
          SettingsSwitch(
            icon: AurixGlyph.externalLink,
            title: 'Keep it visible outside AURIX',
            subtitle: _outsideSubtitle(capability, settings),
            value: settings.dynamicIslandOverlay && capability.granted,
            onChanged: (value) => _toggleOutside(context, ref, value: value),
          ),

        if (settings.dynamicIsland && !capability.exists)
          SettingsNote(text: _unsupportedNote(capability)),

        const SettingsNote(
          text: 'The Dynamic Island is drawn by AURIX, not by your phone. It '
              'sits below whatever your screen already has up there — a notch, '
              'a punch-hole, a cutout or nothing at all — so it looks and '
              'behaves the same on every device.',
        ),
        const SettingsNote(
          text: 'Music keeps playing when you leave AURIX either way. The '
              'media notification and lock-screen controls are always on and '
              'do not depend on this switch — turning the island off never '
              'stops playback or removes them.',
        ),
      ],
    );
  }

  static String _outsideSubtitle(
    IslandCapability capability,
    AppSettings settings,
  ) {
    if (!settings.dynamicIslandOverlay) {
      return 'Draw the island over other apps while music plays. Needs '
          "Android's “Display over other apps” permission.";
    }
    if (!capability.granted) {
      return 'Waiting for permission — tap to open the system setting';
    }
    return 'Shown over other apps while AURIX is in the background';
  }

  static String _unsupportedNote(IslandCapability capability) =>
      switch (capability.reason) {
        IslandUnavailableReason.liveActivityExtensionMissing =>
          'On iOS the island can only leave the app as a Live Activity, and '
              'this build ships no Live Activity extension. The lock screen and '
              'Control Centre still show the current track, artwork and '
              'transport controls while AURIX is in the background.',
        IslandUnavailableReason.liveActivityDisabledByUser =>
          'Live Activities are switched off for AURIX in iOS Settings, so the '
              'island cannot leave the app. The lock screen and Control Centre '
              'still show what is playing.',
        _ =>
          'This platform has no way to draw a floating window outside the app, '
              'so the island stays inside AURIX. Background playback and its '
              'system media controls are unaffected.',
      };

  /// Handles the outside-the-app switch.
  ///
  /// Turning it **on** explains the permission first and only opens the system
  /// screen if the user agrees — there is no path from this file to a
  /// permission request the user did not read a sentence about.
  ///
  /// Turning it **off** removes the floating window and nothing else. Playback,
  /// the media session, the notification and the lock screen are untouched, and
  /// the system grant is left alone: revoking it is the user's business and
  /// lives in Android's own settings.
  Future<void> _toggleOutside(
    BuildContext context,
    WidgetRef ref, {
    required bool value,
  }) async {
    final settings = ref.read(settingsProvider.notifier);
    final island = ref.read(dynamicIslandControllerProvider.notifier);

    if (!value) {
      await settings.setDynamicIslandOverlay(false);
      return;
    }

    final capability = ref.read(islandCapabilityProvider);
    if (capability.granted) {
      await settings.setDynamicIslandOverlay(true);
      return;
    }

    if (!capability.isRequestable) {
      if (context.mounted) {
        AppSnackbar.warning(context, 'Not available on this device');
      }
      return;
    }

    final agreed = await ConfirmDialog.show(
      context,
      title: 'Show the island over other apps?',
      message: 'Android calls this “Display over other apps”. AURIX needs it '
          'for one thing only: keeping the Dynamic Island on screen after you '
          'leave the app, so you can skip and pause without switching back.\n\n'
          'It does not affect playback, and AURIX draws the island only while '
          'a track is loaded. You can revoke it at any time in Android '
          'Settings, or just switch this off again.',
      confirmLabel: 'Open settings',
    );
    if (!agreed) return;

    // Records the preference before leaving for the system screen, so coming
    // back with the grant in hand puts the island up without a second tap.
    await settings.setDynamicIslandOverlay(true);
    final granted = await island.requestFloatingPermission();

    if (!context.mounted) return;
    if (granted.granted) {
      AppSnackbar.success(context, 'Island will follow you out of AURIX');
    } else {
      AppSnackbar.warning(
        context,
        'Permission not granted — the island stays inside AURIX',
      );
    }
  }
}
