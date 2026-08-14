import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../data/models/playback.dart';
import '../../data/services/spotify_app_remote_service.dart';
import '../../data/services/spotify_player_service.dart';
import '../../playback/playback_mode.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../auth/providers/auth_provider.dart';

/// Spotify Connect device picker.
///
/// This screen is where the app is most explicitly honest about its limits.
/// It lists real devices from `GET /me/player/devices` and — when the list is
/// empty, or the account is not Premium, or the only devices are restricted —
/// explains exactly why, rather than showing an empty list and letting the
/// user conclude the app is broken.
class DevicePickerScreen extends ConsumerStatefulWidget {
  const DevicePickerScreen({super.key});

  @override
  ConsumerState<DevicePickerScreen> createState() => _DevicePickerScreenState();
}

class _DevicePickerScreenState extends ConsumerState<DevicePickerScreen> {
  bool _refreshing = false;
  String? _switchingTo;
  bool _connectingAppRemote = false;

  /// Binds to the Spotify app and starts the current track in it.
  ///
  /// Every failure here has a *different* fix — Spotify missing, remote
  /// control never granted, no Premium — so the reason is surfaced verbatim
  /// rather than folded into one "could not connect".
  Future<void> _connectAppRemote() async {
    if (_connectingAppRemote) return;
    setState(() => _connectingAppRemote = true);

    final controller = ref.read(playerControllerProvider.notifier);
    final error = await controller.connectSpotifyApp();

    if (!mounted) return;
    setState(() => _connectingAppRemote = false);

    if (error == null) {
      AppSnackbar.success(context, 'Connected to Spotify');
      Navigator.of(context).maybePop();
      return;
    }

    if (error.failure == AppRemoteFailure.notInstalled) {
      AppSnackbar.error(context, error.message);
      await launchUrl(
        Uri.parse(AppConstants.spotifyInstallUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    AppSnackbar.error(context, error.message);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    await ref.read(playerControllerProvider.notifier).refreshDevices(force: true);
    if (mounted) setState(() => _refreshing = false);
  }

  @override
  Widget build(BuildContext context) {
    // Timeline-agnostic — nothing here moves with the position.
    final state = ref.watch(playbackStateProvider);
    final connect = state.connect;
    final knownNonPremium = ref.watch(knownNonPremiumProvider);
    final devices = connect.controllableDevices;

    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const AurixIcon(AurixGlyph.chevronDown, size: 30),
          tooltip: 'Close',
        ),
        title: const Text('Connect to a device'),
        centerTitle: true,
        actions: [
          IconButton(
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const AurixIcon(AurixGlyph.refresh),
            tooltip: 'Refresh devices',
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: AppSpacing.huge),
        children: [
          // The Spotify app on this phone, driven over App Remote.
          //
          // Listed first and above the Connect devices because it is the one
          // that works without a second machine — and because its absence was
          // the whole reason this screen used to say "No Spotify device
          // available" to someone holding a phone with Spotify on it. AURIX is
          // not itself a Connect device and never appears in
          // GET /me/player/devices; that endpoint says nothing about whether
          // this tile will work.
          if (SpotifyAppRemoteService.isSupportedPlatform)
            _DeviceTile(
              icon: AurixGlyph.phone,
              name: 'Spotify on this phone',
              subtitle: switch (state.mode) {
                PlaybackMode.appRemote => 'Playing the full track',
                _ => 'Plays full tracks through the Spotify app',
              },
              selected: state.mode == PlaybackMode.appRemote,
              busy: _connectingAppRemote,
              onTap: state.mode == PlaybackMode.appRemote
                  ? null
                  : _connectAppRemote,
              trailing: state.mode == PlaybackMode.appRemote
                  ? null
                  : const _InfoChip(label: 'Connect'),
            ),

          // AURIX's own preview playback — always available, and always honest
          // about what it can do.
          _DeviceTile(
            icon: AurixGlyph.phone,
            name: 'This device',
            subtitle: state.mode == PlaybackMode.preview
                ? 'Playing a 30-second preview'
                : 'Plays 30-second previews only',
            selected: state.mode == PlaybackMode.preview,
            onTap: null,
            trailing: const _InfoChip(label: '0:30'),
          ),

          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSpacing.xxl,
              AppSpacing.page,
              AppSpacing.sm,
            ),
            child: Text(
              'Spotify Connect devices',
              style: AppTypography.headlineSmall,
            ),
          ),

          // Says what this list *is*, because its emptiness used to be read as
          // "AURIX cannot play anything". Connect lists devices signed in to
          // Spotify elsewhere; it has nothing to do with the phone in your
          // hand, which is covered by the tile above.
          const Padding(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.page,
              0,
              AppSpacing.page,
              AppSpacing.md,
            ),
            child: Text(
              'Other devices signed in to Spotify. This list does not include '
              'this phone.',
              style: AppTypography.bodySmall,
            ),
          ),

          // Only when Spotify has actually said the account is not Premium.
          // `!hasPremium` would also be true when Spotify declined to say —
          // the normal case for a Development Mode app since February 2026 —
          // and would then tell a Premium subscriber that Premium is the
          // problem while hiding the "open Spotify on a device" step that
          // would actually fix their silence.
          if (knownNonPremium)
            const _Explainer(
              icon: AurixGlyph.premium,
              title: 'Premium required',
              body:
                  'Spotify only lets apps control playback for Premium accounts. '
                  'AURIX can still browse your library and play previews '
                  'wherever Spotify provides them.',
              linkLabel: 'About Spotify Premium',
              url: AppConstants.spotifyPremiumUrl,
            )
          else if (devices.isEmpty)
            _Explainer(
              icon: AurixGlyph.devices,
              title: connect.status == ConnectStatus.onlyRestrictedDevices
                  ? 'No controllable devices'
                  : 'No devices found',
              body: connect.status == ConnectStatus.onlyRestrictedDevices
                  ? 'The Spotify devices AURIX can see do not accept remote '
                      'control. Chromecast and some car systems work this way.'
                  : 'Open Spotify on your phone, computer, TV or speaker and '
                      'play something briefly. It will appear here within a few '
                      'seconds.',
              actionLabel: 'Check again',
              onAction: _refresh,
            )
          else
            for (final device in devices)
              _DeviceTile(
                icon: _iconFor(device.type),
                name: device.name,
                subtitle: _subtitleFor(device),
                selected: device.isActive,
                busy: _switchingTo == device.id,
                onTap: device.isActive ? null : () => _select(device),
              ),

          if (connect.devices.any((d) => !d.isControllable)) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.xxl,
                AppSpacing.page,
                AppSpacing.sm,
              ),
              child: Text('Not controllable', style: AppTypography.overline),
            ),
            for (final device in connect.devices.where((d) => !d.isControllable))
              _DeviceTile(
                icon: _iconFor(device.type),
                name: device.name,
                subtitle: 'Spotify does not allow remote control of this device',
                selected: false,
                enabled: false,
                onTap: null,
              ),
          ],

          const Padding(
            padding: EdgeInsets.all(AppSpacing.page),
            child: _ConnectFootnote(),
          ),
        ],
      ),
    );
  }

  Future<void> _select(SpotifyDevice device) async {
    setState(() => _switchingTo = device.id);
    final success =
        await ref.read(playerControllerProvider.notifier).selectDevice(device);
    if (!mounted) return;
    setState(() => _switchingTo = null);

    if (success) {
      AppSnackbar.success(context, 'Playing on ${device.name}');
      Navigator.of(context).maybePop();
    }
    // Failure already surfaced through the controller's error message.
  }

  AurixGlyph _iconFor(String type) {
    switch (type.toLowerCase()) {
      case 'computer':
        return AurixGlyph.devices;
      case 'smartphone':
      case 'tablet':
        return AurixGlyph.phone;
      case 'speaker':
        return AurixGlyph.speaker;
      case 'tv':
      case 'castvideo':
        return AurixGlyph.devices;
      case 'avr':
      case 'stb':
        return AurixGlyph.devices;
      case 'automobile':
        return AurixGlyph.devices;
      case 'gameconsole':
        return AurixGlyph.devices;
      default:
        return AurixGlyph.devices;
    }
  }

  String _subtitleFor(SpotifyDevice device) {
    final parts = <String>[
      device.type,
      if (device.isActive) 'Active',
      if (device.isPrivateSession) 'Private session',
      if (device.volumePercent != null) 'Volume ${device.volumePercent}%',
    ];
    return parts.join(' · ');
  }
}

class _DeviceTile extends StatelessWidget {
  const _DeviceTile({
    required this.icon,
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
    this.trailing,
  });

  final AurixGlyph icon;
  final String name;
  final String subtitle;
  final bool selected;
  final VoidCallback? onTap;
  final bool enabled;
  final bool busy;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    final color = !enabled
        ? context.palette.textTertiary
        : selected
            ? accent
            : context.palette.textPrimary;

    return ListTile(
      onTap: enabled ? onTap : null,
      leading: AurixIcon(icon, size: 26, color: color),
      title: Text(name, style: AppTypography.titleMedium.copyWith(color: color)),
      subtitle: Text(subtitle, style: AppTypography.bodySmall),
      trailing: busy
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : trailing ??
              (selected
                  ? AurixIcon(AurixGlyph.checkCircle, color: accent, size: 22)
                  : null),
    );
  }
}

class _Explainer extends StatelessWidget {
  const _Explainer({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
    this.linkLabel,
    this.url,
  });

  final AurixGlyph icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  final String? linkLabel;
  final String? url;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AurixIcon(icon, size: 20, color: context.palette.textSecondary),
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: AppTypography.titleMedium)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(body, style: AppTypography.bodySmall.copyWith(height: 1.55)),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 34),
              ),
              child: Text(actionLabel!),
            ),
          ],
          if (linkLabel != null && url != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse(url!),
                mode: LaunchMode.externalApplication,
              ),
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 34),
              ),
              child: Text(linkLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 2),
      decoration: BoxDecoration(
        color: context.palette.surfaceHighest,
        borderRadius: BorderRadius.circular(AppRadius.xs),
      ),
      child: Text(label, style: AppTypography.labelSmall),
    );
  }
}

class _ConnectFootnote extends StatelessWidget {
  const _ConnectFootnote();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: AurixIcon(
            AurixGlyph.info,
            size: 15,
            color: context.palette.textTertiary,
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            'AURIX controls playback through Spotify Connect — your Spotify '
            'app does the playing, this app does the choosing. Audio is never '
            'downloaded or stored by AURIX.',
            style: AppTypography.bodySmall.copyWith(
              fontSize: 11,
              color: context.palette.textTertiary,
              height: 1.5,
            ),
          ),
        ),
      ],
    );
  }
}
