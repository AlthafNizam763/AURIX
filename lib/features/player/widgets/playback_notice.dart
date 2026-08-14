import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../playback/playback_mode.dart';
import '../../../playback/player_controller.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// Explains a playback limitation, with the action that resolves it.
///
/// ## Why this widget exists
///
/// A third-party Spotify client hits real, unavoidable walls: no Premium, no
/// active device, no preview for a given track. The tempting shortcut is to
/// hide those cases and let the play button quietly do nothing. This widget is
/// the opposite choice — it names the wall and offers the way through it.
///
/// It renders nothing when playback is working normally, so it costs the user
/// no attention in the common case.
class PlaybackNotice extends ConsumerWidget {
  const PlaybackNotice({required this.state, super.key});

  final AurixPlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limitation = state.limitation;
    if (limitation == null) return const SizedBox.shrink();

    // Non-blocking notices (a preview is playing) are already summarised under
    // the progress bar; repeating them here would be noise.
    if (!limitation.isBlocking && state.isPlaying) {
      return const SizedBox.shrink();
    }

    final blocking = limitation.isBlocking;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: blocking
            ? context.palette.attention.withValues(alpha: 0.14)
            : context.palette.surfaceElevated.withValues(alpha: 0.72),
        borderRadius: AppRadius.card,
        border: Border.all(
          color: blocking
              ? context.palette.attention.withValues(alpha: 0.4)
              : Colors.transparent,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(
            blocking ? AurixGlyph.warning : AurixGlyph.info,
            size: 18,
            color: blocking ? context.palette.attention : context.palette.textSecondary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  limitation.headline,
                  style: AppTypography.titleSmall.copyWith(
                    color: blocking ? context.palette.attention : context.palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  limitation.detail,
                  style: AppTypography.bodySmall.copyWith(
                    fontSize: 11.5,
                    height: 1.45,
                  ),
                ),
                if (limitation.action != null) ...[
                  const SizedBox(height: AppSpacing.xs),
                  _RemedyButton(
                    remedy: limitation.action!,
                    onRetry: () => ref
                        .read(playerControllerProvider.notifier)
                        .refreshDevices(force: true),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RemedyButton extends StatelessWidget {
  const _RemedyButton({required this.remedy, required this.onRetry});

  final PlaybackRemedy remedy;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final (label, action) = switch (remedy) {
      PlaybackRemedy.chooseDevice => (
        'Choose a device',
        () => context.pushDistinct(RouteNames.devices),
      ),
      PlaybackRemedy.learnAboutPremium => (
        'About Spotify Premium',
        () => launchUrl(
          Uri.parse(AppConstants.spotifyPremiumUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
      PlaybackRemedy.retry => ('Try again', onRetry),
      // Deep-links to Spotify's Play Store listing. `market://` opens the
      // store app directly where one exists; url_launcher falls back to the
      // https form otherwise, and that form is what iOS uses.
      PlaybackRemedy.installSpotify => (
        'Install Spotify',
        () => launchUrl(
          Uri.parse(AppConstants.spotifyInstallUrl),
          mode: LaunchMode.externalApplication,
        ),
      ),
    };

    return TextButton(
      onPressed: () => action(),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: EdgeInsets.zero,
        textStyle: AppTypography.labelMedium.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      child: Text(label),
    );
  }
}
