import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/constants/app_constants.dart';
import '../../core/providers/app_providers.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../playback/playback_mode.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/aurix_avatar.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../auth/providers/auth_provider.dart';
import '../dynamic_island/widgets/island_settings_section.dart';
import '../onboarding/providers/onboarding_provider.dart';
import 'providers/settings_provider.dart';
import 'widgets/settings_widgets.dart';

/// Settings.
///
/// Groups mirror what the user thinks about — Account, Playback, Audio,
/// Notifications, Appearance, Privacy, Storage — and every control here does
/// something real. Where Spotify's API gives AURIX no control (bitrate, for
/// instance), the row says so rather than presenting a switch that is theatre.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsProvider);
    final controller = ref.read(settingsProvider.notifier);
    final user = ref.watch(currentUserProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const AurixIcon(AurixGlyph.back),
          tooltip: 'Back',
        ),
        title: const Text('Settings'),
      ),
      body: ContentBounds(
        child: ListView(
          padding: const EdgeInsets.only(bottom: AppSpacing.huge),
          children: [
            // ---- Account ---------------------------------------------
            const SettingsGroup(title: 'Account'),
            SettingsTile(
              icon: AurixGlyph.profile,
              // The account row's subject is the user, so it carries the user's
              // face — the same avatar the home header and the profile screen
              // show, from the same shared state. The glyph above stays as the
              // signed-out fallback.
              leading: user == null
                  ? null
                  : AurixAvatar.of(size: AppSizes.avatarSm),
              title: user?.displayName ?? 'Not signed in',
              // The email, not the Spotify plan and country this used to show.
              // Neither of those is a fact about an AURIX account, and the
              // address is what tells someone *which* account they are looking
              // at — which is the question a settings row is answering.
              subtitle: user?.email,
              // Push, not `go`. Profile stopped being a shell tab when the bar
              // went down to three destinations; it is a page on the root
              // navigator now, and `go` to one of those replaces the shell
              // instead of covering it — which left Back with nothing under it
              // and closed the app from a screen two taps deep.
              onTap: () => context.pushDistinct(RouteNames.profile),
            ),

            // ---- Playback --------------------------------------------
            const SettingsGroup(title: 'Playback'),
            SettingsTile(
              icon: AurixGlyph.play,
              title: 'Preferred playback',
              subtitle: settings.playbackPreference.label,
              onTap: () => _choosePlayback(context, ref, settings.playbackPreference),
            ),
            SettingsTile(
              icon: AurixGlyph.devices,
              title: 'Spotify Connect devices',
              subtitle: 'Choose where full tracks play',
              onTap: () => context.pushDistinct(RouteNames.devices),
            ),
            SettingsSwitch(
              icon: AurixGlyph.sparkle,
              title: 'Autoplay similar music',
              subtitle: 'Keep playing related tracks when the queue ends',
              value: settings.autoplaySimilar,
              onChanged: controller.setAutoplaySimilar,
            ),
            SettingsSwitch(
              icon: AurixGlyph.share,
              title: 'Gapless playback',
              subtitle: 'Remove silence between tracks where possible',
              value: settings.gaplessPlayback,
              onChanged: controller.setGapless,
            ),
            SettingsSlider(
              icon: AurixGlyph.equalizer,
              title: 'Crossfade',
              value: settings.crossfadeSeconds.toDouble(),
              max: 12,
              divisions: 12,
              labelBuilder: (value) =>
                  value == 0 ? 'Off' : '${value.round()} seconds',
              onChanged: (value) => controller.setCrossfadeSeconds(value.round()),
            ),

            // ---- Audio quality ---------------------------------------
            const SettingsGroup(title: 'Audio quality'),
            SettingsTile(
              icon: AurixGlyph.equalizer,
              title: 'Streaming quality',
              subtitle: settings.streamingQuality.label,
              onTap: () => _chooseQuality(context, ref, settings.streamingQuality),
            ),
            SettingsSwitch(
              icon: AurixGlyph.equalizer,
              title: 'Stream on mobile data',
              subtitle: 'Allow preview streaming when not on Wi-Fi',
              value: settings.streamOverCellular,
              onChanged: controller.setStreamOverCellular,
            ),
            SettingsSwitch(
              icon: AurixGlyph.equalizer,
              title: 'Normalise volume',
              subtitle: 'Even out loudness between tracks',
              value: settings.normalizeVolume,
              onChanged: controller.setNormalizeVolume,
            ),
            const SettingsNote(
              text: 'Bitrate is set by whichever Spotify client is playing. '
                  'The Web API exposes no bitrate control, so AURIX does not '
                  'pretend to offer one — these settings govern the previews it '
                  'streams itself.',
            ),

            // ---- Notifications ---------------------------------------
            const SettingsGroup(title: 'Notifications'),
            SettingsSwitch(
              icon: AurixGlyph.album,
              title: 'New releases',
              subtitle: 'From artists you follow',
              value: settings.notifyNewReleases,
              onChanged: controller.setNotifyNewReleases,
            ),
            SettingsSwitch(
              icon: AurixGlyph.sparkle,
              title: 'Recommendations',
              subtitle: 'Occasional suggestions based on your listening',
              value: settings.notifyRecommendations,
              onChanged: controller.setNotifyRecommendations,
            ),
            const SettingsNote(
              text: 'These control the in-app notification centre. AURIX has '
                  'no push-notification backend, so nothing is sent to your '
                  'device while the app is closed.',
            ),

            // ---- Appearance ------------------------------------------
            const SettingsGroup(title: 'Appearance'),
            SettingsTile(
              icon: AurixGlyph.moon,
              title: 'Theme',
              subtitle: switch (settings.themeMode) {
                ThemeMode.dark => 'Dark',
                ThemeMode.light => 'Light',
                ThemeMode.system => 'Match system',
              },
              onTap: () => _chooseTheme(context, ref, settings.themeMode),
            ),
            // The island is three rows and a pile of platform-dependent copy —
            // whether a floating surface exists here at all, and what to say
            // when it does not. It lives in its own widget so this screen keeps
            // reading as a list of settings.
            const DynamicIslandSettingsSection(),
            SettingsSwitch(
              icon: AurixGlyph.motion,
              title: 'Reduce motion',
              subtitle: 'Turn off decorative animations and shimmer',
              value: settings.reduceMotion,
              onChanged: controller.setReduceMotion,
            ),
            // A plain local preference now.
            //
            // This switch used to be three-valued in effect: Spotify's own
            // account filter outranked it, and an account with the filter
            // *locked* had the switch disabled because the decision was
            // Spotify's to make. An AURIX account has no such filter — there is
            // no server-side policy to defer to — so the preference is simply
            // the user's, and the row says only what it does.
            SettingsSwitch(
              icon: AurixGlyph.explicit,
              title: 'Show explicit content',
              subtitle: 'Display the explicit marker on tracks',
              value: settings.showExplicit,
              onChanged: controller.setShowExplicit,
            ),

            // ---- Privacy ----------------------------------------------
            const SettingsGroup(title: 'Privacy'),
            SettingsTile(
              icon: AurixGlyph.history,
              title: 'Clear search history',
              subtitle: 'Stored only on this device',
              onTap: () => _clearSearchHistory(context, ref),
            ),
            const SettingsNote(
              text: 'AURIX stores nothing on a server. Tokens live in your '
                  'device keychain; search history, settings and cached '
                  'metadata live in app storage and go away when you log out.',
            ),

            // ---- Storage ----------------------------------------------
            const SettingsGroup(title: 'Storage'),
            SettingsTile(
              icon: AurixGlyph.broom,
              title: 'Clear cached metadata',
              subtitle: 'Albums, artists and playlists you have viewed',
              onTap: () => _clearCache(context, ref),
            ),
            const SettingsNote(
              text: 'No audio is ever cached. AURIX has no access to '
                  "Spotify's audio files and storing them would breach the "
                  'Developer Terms.',
            ),

            // ---- About -------------------------------------------------
            const SettingsGroup(title: 'About'),
            SettingsTile(
              icon: AurixGlyph.sparkle,
              title: 'Replay the intro',
              subtitle: 'Show the welcome screens again',
              onTap: () => _replayIntro(context, ref),
            ),
            SettingsTile(
              icon: AurixGlyph.info,
              title: 'About ${AppConstants.appName}',
              onTap: () => context.pushDistinct(RouteNames.about),
            ),

            const SizedBox(height: AppSpacing.xl),

            Padding(
              padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
              child: OutlinedButton.icon(
                onPressed: () => _confirmSignOut(context, ref),
                icon: const AurixIcon(AurixGlyph.logout, size: 18),
                label: const Text('Log out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.palette.attention,
                  side: BorderSide(color: context.palette.attention),
                  minimumSize: const Size(double.infinity, 48),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---- Pickers -----------------------------------------------------------

  void _choosePlayback(
    BuildContext context,
    WidgetRef ref,
    PlaybackPreference current,
  ) {
    final controller = ref.read(settingsProvider.notifier);
    BottomSheetMenu.show(
      context,
      title: 'Preferred playback',
      note: 'AURIX falls back automatically when your first choice is not '
          'available for a track.',
      actions: [
        for (final option in PlaybackPreference.values)
          SheetAction(
            icon: option == PlaybackPreference.connectFirst
                ? AurixGlyph.devices
                : AurixGlyph.phone,
            label: option.label,
            subtitle: option.description,
            trailing: option == current
                ? AurixIcon(AurixGlyph.check, color: context.palette.accent)
                : null,
            onTap: () => controller.setPlaybackPreference(option),
          ),
      ],
    );
  }

  void _chooseQuality(
    BuildContext context,
    WidgetRef ref,
    StreamingQuality current,
  ) {
    final controller = ref.read(settingsProvider.notifier);
    BottomSheetMenu.show(
      context,
      title: 'Streaming quality',
      actions: [
        for (final option in StreamingQuality.values)
          SheetAction(
            icon: AurixGlyph.equalizer,
            label: option.label,
            subtitle: option.description,
            trailing: option == current
                ? AurixIcon(AurixGlyph.check, color: context.palette.accent)
                : null,
            onTap: () => controller.setStreamingQuality(option),
          ),
      ],
    );
  }

  void _chooseTheme(BuildContext context, WidgetRef ref, ThemeMode current) {
    final controller = ref.read(settingsProvider.notifier);
    BottomSheetMenu.show(
      context,
      title: 'Theme',
      note: '${AppConstants.appName} is designed dark-first; the light theme '
          'reuses the same palette.',
      actions: [
        for (final option in ThemeMode.values)
          SheetAction(
            icon: switch (option) {
              ThemeMode.dark => AurixGlyph.moon,
              ThemeMode.light => AurixGlyph.sun,
              ThemeMode.system => AurixGlyph.auto,
            },
            label: switch (option) {
              ThemeMode.dark => 'Dark',
              ThemeMode.light => 'Light',
              ThemeMode.system => 'Match system',
            },
            trailing: option == current
                ? AurixIcon(AurixGlyph.check, color: context.palette.accent)
                : null,
            onTap: () => controller.setThemeMode(option),
          ),
      ],
    );
  }

  // The colourway picker used to live here, between the theme picker and
  // `_replayIntro`. It offered Miles / Spider-Verse / Neon and is gone with
  // the monochrome identity — a palette with a single accent has nothing to
  // vary, and a sheet offering three shades of black is a setting that appears
  // to do nothing. Appearance is now one control: light, dark or system.

  /// Clears the "seen" flag. The router watches it, so the app moves to the
  /// intro on its own — this does not navigate.
  void _replayIntro(BuildContext context, WidgetRef ref) {
    ref.read(onboardingCompleteProvider.notifier).replay();
  }

  // ---- Destructive actions -----------------------------------------------

  Future<void> _clearSearchHistory(BuildContext context, WidgetRef ref) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Clear search history?',
      message: 'Your recent searches on this device will be removed.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;

    await ref.read(searchRepositoryProvider).clearRecentSearches();
    if (context.mounted) AppSnackbar.success(context, 'Search history cleared');
  }

  Future<void> _clearCache(BuildContext context, WidgetRef ref) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Clear cached metadata?',
      message: 'Saved album, artist and playlist details will be re-downloaded '
          'the next time you open them. Nothing in your Spotify account changes.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (!confirmed || !context.mounted) return;

    await ref.read(metadataCacheProvider).clear();
    if (!context.mounted) return;

    // Invalidate the caches that read from it so the UI does not keep showing
    // data that no longer exists on disk.
    ref.invalidate(homeRepositoryProvider);
    AppSnackbar.success(context, 'Cached metadata cleared');
  }

  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Log out?',
      message: 'Your Spotify tokens and cached library will be removed from '
          'this device. Nothing changes on Spotify itself.',
      confirmLabel: 'Log out',
      destructive: true,
    );
    if (confirmed) {
      await ref.read(authControllerProvider.notifier).signOut();
    }
  }
}
