import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/env.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../shared/widgets/brand/aurix_logo.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';

/// Shown when no Spotify Client ID is configured.
///
/// This is a developer-facing screen, and it is worth having: without it, a
/// fresh clone fails at the OAuth redirect with an opaque Spotify error page,
/// which is a genuinely confusing first five minutes. Here the exact steps and
/// the exact redirect URI to register are on screen and copyable.
class SetupRequiredScreen extends StatelessWidget {
  const SetupRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ContentBounds(
          maxWidth: 560,
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: context.pageGutter,
              vertical: AppSpacing.xxxl,
            ),
            children: [
              const Center(child: AurixLogoBadge(size: 84)),
              const SizedBox(height: AppSpacing.xxl),
              const Text(
                'One step before you start',
                style: AppTypography.displaySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.md),
              const Text(
                '${AppConstants.appName} talks to the official Spotify Web API, '
                'which needs a Client ID from your own Spotify application.',
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: AppSpacing.xxxl),

              const _Step(
                number: 1,
                title: 'Create a Spotify app',
                body: 'Open the Spotify Developer Dashboard and create an '
                    'application. Any name works.',
              ),
              _Step(
                number: 2,
                title: 'Register the redirect URI',
                body: 'Add this exact value under "Redirect URIs". '
                    'It must match character for character.',
                copyable: Env.spotifyRedirectUri,
              ),
              const _Step(
                number: 3,
                title: 'Enable the Web API',
                body: 'Under "Which API/SDKs are you planning to use?", tick '
                    '"Web API". AURIX uses no other Spotify SDK.',
              ),
              const _Step(
                number: 4,
                title: 'Add the Client ID',
                body: 'Copy .env.example to .env and paste the Client ID into '
                    'SPOTIFY_CLIENT_ID. There is no client secret — AURIX '
                    'uses the PKCE flow, so none is needed or wanted.',
                copyable: 'SPOTIFY_CLIENT_ID=your_client_id_here',
              ),
              const _Step(
                number: 5,
                title: 'Restart the app',
                body: 'Stop and re-run — .env is bundled as an asset, so a hot '
                    'reload will not pick up the change.',
                isLast: true,
              ),

              const SizedBox(height: AppSpacing.xl),

              FilledButton.icon(
                onPressed: () => _open(context, AppConstants.spotifyDashboardUrl),
                icon: const AurixIcon(AurixGlyph.externalLink, size: 18),
                label: const Text('Open Spotify Developer Dashboard'),
              ),

              const SizedBox(height: AppSpacing.xxl),

              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: context.palette.surface,
                  borderRadius: AppRadius.card,
                  border: Border.all(color: context.palette.hairline),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AurixIcon(AurixGlyph.terminal, size: 18, color: context.palette.textTertiary),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        'Prefer not to use a .env file? Pass the values at build '
                        'time instead:\n'
                        'flutter run --dart-define=SPOTIFY_CLIENT_ID=…',
                        style: AppTypography.bodySmall.copyWith(height: 1.6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      AppSnackbar.error(context, "Couldn't open the browser. Visit $url manually.");
    }
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.number,
    required this.title,
    required this.body,
    this.copyable,
    this.isLast = false,
  });

  final int number;
  final String title;
  final String body;
  final String? copyable;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Column(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: context.palette.accentSoft,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Text(
                  '$number',
                  style: AppTypography.labelMedium.copyWith(
                    color: context.palette.accent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              if (!isLast)
                Expanded(
                  child: Container(width: 1.5, color: context.palette.hairline),
                ),
            ],
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.xxl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTypography.titleMedium),
                  const SizedBox(height: AppSpacing.xs),
                  Text(body, style: AppTypography.bodySmall.copyWith(height: 1.55)),
                  if (copyable != null) ...[
                    const SizedBox(height: AppSpacing.md),
                    _CopyableValue(value: copyable!),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableValue extends StatelessWidget {
  const _CopyableValue({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (context.mounted) AppSnackbar.success(context, 'Copied to clipboard');
      },
      borderRadius: AppRadius.field,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm + 2,
        ),
        decoration: BoxDecoration(
          color: context.palette.surfaceElevated,
          borderRadius: AppRadius.field,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                value,
                style: AppTypography.bodySmall.copyWith(
                  color: context.palette.accent,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            AurixIcon(AurixGlyph.copy, size: 15, color: context.palette.textTertiary),
          ],
        ),
      ),
    );
  }
}
