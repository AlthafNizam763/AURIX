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

/// Shown when no Firebase project is configured.
///
/// This is a developer-facing screen, and it is worth having: without it a
/// fresh clone comes up permanently signed-out with a console warning nobody
/// reads, which is a genuinely confusing first five minutes. Here the exact
/// keys to set are on screen and copyable.
///
/// It used to explain the Spotify developer dashboard, because a Client ID was
/// what the app could not start without. Spotify is now optional — an import
/// provider reached from Settings — so its setup instructions live with the
/// import screen, and this one covers the thing that actually blocks startup.
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
                '${AppConstants.appName} keeps your account, playlists and '
                'library in Firebase. Point this build at a Firebase project '
                'and it will start.',
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),

              const SizedBox(height: AppSpacing.xxxl),

              const _Step(
                number: 1,
                title: 'Create a Firebase project',
                body: 'Open the Firebase console and create a project. Then '
                    'add an app to it for each platform you build for — '
                    'Android, iOS, web.',
              ),
              const _Step(
                number: 2,
                title: 'Turn on Email/Password sign-in',
                body: 'Authentication → Sign-in method → Email/Password → '
                    'Enable. Without this, registration fails with '
                    '"operation-not-allowed".',
              ),
              const _Step(
                number: 3,
                title: 'Create the Firestore database',
                body: 'Build → Firestore Database → Create. Start in '
                    'production mode, then deploy the rules that ship with '
                    'this repository — they are what stop one account reading '
                    "another's library.",
                copyable: 'firebase deploy --only firestore:rules',
              ),
              const _Step(
                number: 4,
                title: 'Add the project keys',
                body: 'Copy .env.example to .env and paste the values from '
                    'Project settings → Your apps. None of them is a secret — '
                    'access is decided by the security rules, not by these.',
                copyable: 'FIREBASE_PROJECT_ID=your-project-id',
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
                onPressed: () => _open(context, AppConstants.firebaseConsoleUrl),
                icon: const AurixIcon(AurixGlyph.externalLink, size: 18),
                label: const Text('Open the Firebase console'),
              ),

              const SizedBox(height: AppSpacing.xxl),

              _Note(
                text: Env.isApiConfigured
                    ? 'Configuration looks complete. If you are still seeing '
                          'this screen, restart the app so the new .env is '
                          'read.'
                    : Env.apiConfigurationHint,
              ),

              const SizedBox(height: AppSpacing.md),

              const _Note(
                text: 'Prefer not to use a .env file? Pass the values at build '
                    'time instead:\n'
                    'flutter run --dart-define=FIREBASE_PROJECT_ID=…',
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

/// A boxed aside — what is missing, or how to do the same thing another way.
class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(
            AurixGlyph.terminal,
            size: 18,
            color: context.palette.textTertiary,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodySmall.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
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
