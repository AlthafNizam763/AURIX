import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/env.dart';
import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/repositories/auth_repository.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import 'providers/auth_provider.dart';

/// Shown when sign-in succeeded but Spotify answers `403` to everything.
///
/// ## Why this screen exists
///
/// A `403` on `GET /me` is unambiguous. That endpoint requires no scope, is
/// never restricted by quota mode, and works for any valid token — so if it is
/// refused, Spotify is rejecting the *application* on behalf of this *user*.
///
/// Without this screen the app looks signed in, greets the user by name from a
/// cached profile, and then shows a completely empty Home with no explanation.
/// That is a genuinely baffling state to debug, and the fix is two clicks away
/// in a dashboard the user already has open.
///
/// ## Why it reports the response
///
/// The screen used to name two likely causes and show nothing about the actual
/// failure, so there was no way to tell which one applied — or whether Spotify
/// had said something else entirely. It now prints Spotify's own `error
/// .message`, the endpoint, and the Client ID the build is running as, because
/// the Client ID answers the question people get wrong most often: *which*
/// dashboard application is refusing them.
class AccessDeniedScreen extends ConsumerStatefulWidget {
  const AccessDeniedScreen({super.key});

  @override
  ConsumerState<AccessDeniedScreen> createState() => _AccessDeniedScreenState();
}

class _AccessDeniedScreenState extends ConsumerState<AccessDeniedScreen> {
  bool _checking = false;

  Future<void> _recheck() async {
    if (_checking) return;
    setState(() => _checking = true);

    final granted = await ref.read(authControllerProvider.notifier).recheckAccess();

    if (!mounted) return;
    setState(() => _checking = false);

    if (!granted) {
      final denial = ref.read(accessDenialProvider);
      AppSnackbar.warning(
        context,
        denial?.isFixableBySigningInAgain ?? false
            ? 'Still refused, and Spotify names a missing permission — sign in '
                  'again to re-grant it.'
            : 'Spotify is still refusing this account. Changes can take a minute.',
      );
    }
    // On success the router redirects to Home.
  }

  Future<void> _open(String url) async {
    final launched = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!launched && mounted) {
      AppSnackbar.error(context, "Couldn't open the browser. Visit $url manually.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final denial = ref.watch(accessDenialProvider);
    final cause = denial?.cause ?? AccessDenialCause.unspecified;

    // A scope 403 is the one that a fresh consent actually clears, so it gets
    // the opposite advice to the rest.
    final explanation = cause == AccessDenialCause.insufficientScope
        ? 'Spotify says the token is missing a permission it needs, so '
              'signing in again — and accepting the consent screen — should '
              'fix it.'
        : 'That means the Spotify application below has not granted this '
              'account access. It is fixed in the developer dashboard, not in '
              '${AppConstants.appName}.';

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: SafeArea(
        child: ContentBounds(
          maxWidth: 560,
          child: ListView(
            padding: EdgeInsets.symmetric(
              horizontal: context.pageGutter,
              vertical: AppSpacing.xxl,
            ),
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: context.palette.surfaceElevated,
                  shape: BoxShape.circle,
                ),
                child: AurixIcon(
                  AurixGlyph.profile,
                  size: 32,
                  color: context.palette.attention,
                ),
              ),

              const SizedBox(height: AppSpacing.xl),

              const Text(
                'Spotify is blocking this account',
                style: AppTypography.displaySmall,
              ),

              const SizedBox(height: AppSpacing.md),

              Text(
                'Sign-in worked and your token is valid, but Spotify is '
                'returning "403 Forbidden" for every request — including the '
                'basic profile endpoint.\n\n$explanation',
                style: AppTypography.bodyMedium,
              ),

              const SizedBox(height: AppSpacing.xl),

              _SpotifySaid(denial: denial),

              const SizedBox(height: AppSpacing.xxxl),

              _Cause(
                number: 1,
                title: 'Add your account to the app',
                likelihood: switch (cause) {
                  AccessDenialCause.userNotRegistered => 'Confirmed by Spotify',
                  AccessDenialCause.insufficientScope => 'Unlikely here',
                  AccessDenialCause.unspecified => 'Most likely',
                },
                body:
                    'A new Spotify app starts in Development Mode, where only '
                    'accounts you explicitly list may use it — up to five, '
                    'since February 2026.\n\n'
                    'Dashboard → your app → Settings → User Management → '
                    '"Add new user". Enter the Spotify account\'s full name and '
                    'the email address it is registered with — the account you '
                    'just signed in with, which is not necessarily the account '
                    'that owns the dashboard app.',
              ),

              // Listed because it is new, invisible from inside the app, and
              // produces exactly this symptom. Spotify's February 2026 rules
              // require the *owner* of a Development Mode app to hold an
              // active Premium subscription; the app stops working the moment
              // that lapses and resumes when they resubscribe. Nothing in the
              // 403 body distinguishes it from the allowlist case, so it is
              // offered as a thing to check rather than a diagnosis.
              _Cause(
                number: 2,
                title: "The app owner's Spotify Premium may have lapsed",
                likelihood: cause == AccessDenialCause.insufficientScope
                    ? 'Ruled out'
                    : 'Worth checking',
                body:
                    'Since February 2026 a Development Mode app only works '
                    'while the account that owns it has an active Spotify '
                    'Premium subscription. That is the dashboard account — not '
                    'necessarily the one signing in.\n\n'
                    'If it lapsed, the app works again as soon as that account '
                    'resubscribes.',
              ),

              _Cause(
                number: 3,
                title: 'Tick "Web API" in the app settings',
                likelihood: cause == AccessDenialCause.unspecified
                    ? 'Also common'
                    : 'Ruled out',
                body:
                    'If your app does not declare the Web API, Spotify rejects '
                    'every call to api.spotify.com.\n\n'
                    'Dashboard → your app → Settings → Edit → "Which API/SDKs '
                    'are you planning to use?" → tick Web API → Save.',
                isLast: true,
              ),

              const SizedBox(height: AppSpacing.xxl),

              FilledButton.icon(
                onPressed: () => _open(AppConstants.spotifyDashboardUrl),
                icon: const AurixIcon(AurixGlyph.externalLink, size: 18),
                label: const Text('Open Spotify Dashboard'),
              ),

              const SizedBox(height: AppSpacing.md),

              OutlinedButton.icon(
                onPressed: _checking ? null : _recheck,
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const AurixIcon(AurixGlyph.refresh, size: 18),
                label: Text(_checking ? 'Checking…' : "I've done that — check again"),
              ),

              const SizedBox(height: AppSpacing.xxl),

              Center(
                child: TextButton(
                  onPressed: () =>
                      ref.read(authControllerProvider.notifier).signOut(),
                  style: TextButton.styleFrom(
                    foregroundColor: context.palette.textSecondary,
                  ),
                  child: const Text('Sign in with a different account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The evidence: what Spotify actually returned, and which Spotify
/// application it returned it to.
///
/// The Client ID is the line that resolves most of these reports. A 403 is
/// decided per application, and the usual mistake is fixing the dashboard
/// entry for a *different* app than the one `.env` points at. It is public
/// under PKCE, so showing it gives nothing away.
class _SpotifySaid extends StatelessWidget {
  const _SpotifySaid({required this.denial});

  final AccessDenial? denial;

  @override
  Widget build(BuildContext context) {
    final clientId = Env.spotifyClientId;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
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
              AurixIcon(
                AurixGlyph.terminal,
                size: 15,
                color: context.palette.textTertiary,
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                'What Spotify returned',
                style: AppTypography.labelMedium.copyWith(
                  color: context.palette.textSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _DetailLine(
            label: 'Status',
            value: '${denial?.statusCode ?? 403} Forbidden',
          ),
          _DetailLine(label: 'Endpoint', value: denial?.endpoint ?? '/me'),
          _DetailLine(
            label: 'Message',
            value: denial?.spotifyMessage ?? '(none — Spotify sent no reason)',
          ),
          _DetailLine(
            label: 'Client ID',
            value: clientId.isEmpty ? '(missing from .env)' : clientId,
            isLast: true,
          ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({
    required this.label,
    required this.value,
    this.isLast = false,
  });

  final String label;
  final String value;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 74,
            child: Text(
              label,
              style: AppTypography.bodySmall.copyWith(
                color: context.palette.textTertiary,
              ),
            ),
          ),
          Expanded(
            // Selectable so the Client ID and Spotify's wording can be copied
            // straight into the dashboard or a bug report.
            child: SelectableText(
              value,
              style: AppTypography.bodySmall.copyWith(
                color: context.palette.textSecondary,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Courier New', 'monospace'],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Cause extends StatelessWidget {
  const _Cause({
    required this.number,
    required this.title,
    required this.likelihood,
    required this.body,
    this.isLast = false,
  });

  final int number;
  final String title;
  final String likelihood;
  final String body;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 0 : AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 24,
                height: 24,
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
              const SizedBox(width: AppSpacing.md),
              Expanded(child: Text(title, style: AppTypography.titleMedium)),
              Text(likelihood, style: AppTypography.labelSmall),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.only(left: 36),
            child: Text(
              body,
              style: AppTypography.bodySmall.copyWith(height: 1.6),
            ),
          ),
        ],
      ),
    );
  }
}
