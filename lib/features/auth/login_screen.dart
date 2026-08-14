import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../shared/widgets/brand/aurix_logo.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import 'providers/auth_provider.dart';

/// Sign-in.
///
/// One button, because there is one supported path: Spotify's OAuth
/// authorization page in a system browser (PKCE). The screen is honest about
/// what happens next and what AURIX will and will not be able to do — the
/// Premium caveat especially, since discovering it after signing in is the
/// single most frustrating way to learn it.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _signingIn = false;

  Future<void> _signIn() async {
    if (_signingIn) return;
    setState(() => _signingIn = true);

    final success = await ref.read(authControllerProvider.notifier).signIn();

    if (!mounted) return;
    setState(() => _signingIn = false);

    if (!success) {
      final message = ref.read(authControllerProvider).errorMessage;
      // A cancelled sign-in leaves no message — the user meant to back out.
      if (message != null) AppSnackbar.error(context, message);
    }
    // On success the router's redirect takes over; navigating here too would
    // race it.
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = context.isLandscape;

    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              context.palette.brandSurfaceHigh,
              context.palette.brandSurfaceLow,
              context.palette.ground,
            ],
            stops: const [0, 0.45, 1],
          ),
        ),
        child: SafeArea(
          child: ContentBounds(
            maxWidth: 480,
            // The column below uses a Spacer to push the sign-in block to the
            // bottom on a tall screen, while still scrolling on a short one.
            // That needs both halves of this sandwich:
            //
            //   * `minHeight` from the real viewport, so short content fills
            //     the screen. Measuring the box rather than deriving it from
            //     screen height keeps it correct with a notch, a keyboard, or
            //     in landscape.
            //   * `IntrinsicHeight`, so the Column gets a *finite* height.
            //     A SingleChildScrollView hands its child an unbounded
            //     maxHeight, and `Spacer`/`Expanded` cannot lay out against
            //     infinity — the whole subtree fails its `hasSize` assertion.
            child: LayoutBuilder(
              builder: (context, viewport) => SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: context.pageGutter,
                  vertical: AppSpacing.xxl,
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (viewport.maxHeight - (AppSpacing.xxl * 2))
                        .clamp(0.0, double.infinity),
                  ),
                  child: IntrinsicHeight(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: isLandscape ? AppSpacing.lg : AppSpacing.huge,
                        ),

                        Center(
                          child: const AurixLogoBadge(size: 96)
                              .animate()
                              .fadeIn(duration: 520.ms)
                              .scale(
                                begin: const Offset(0.86, 0.86),
                                curve: Curves.easeOutBack,
                              ),
                        ),

                        const SizedBox(height: AppSpacing.xxxl),

                        const Text(
                              'Your Spotify library,\nbeautifully rearranged.',
                              style: AppTypography.displaySmall,
                              textAlign: TextAlign.center,
                            )
                            .animate(delay: 140.ms)
                            .fadeIn()
                            .slideY(begin: 0.2, end: 0),

                        const SizedBox(height: AppSpacing.md),

                        const Text(
                          'Sign in with Spotify to browse your playlists, follow '
                          'artists and control playback across your devices.',
                          style: AppTypography.bodyMedium,
                          textAlign: TextAlign.center,
                        ).animate(delay: 220.ms).fadeIn(),

                        const Spacer(),
                        const SizedBox(height: AppSpacing.xxxl),

                        const _CapabilityRow(
                          icon: AurixGlyph.library,
                          text:
                              'Your playlists, albums, artists and liked songs',
                        ),
                        const _CapabilityRow(
                          icon: AurixGlyph.devices,
                          text:
                              'Full playback on your Spotify devices — Premium only',
                        ),
                        const _CapabilityRow(
                          icon: AurixGlyph.lock,
                          text:
                              'Tokens stay in your device keychain. No password is shared.',
                        ),

                        const SizedBox(height: AppSpacing.xxxl),

                        FilledButton(
                              onPressed: _signingIn ? null : _signIn,
                              style: FilledButton.styleFrom(
                                minimumSize: const Size(0, 54),
                                textStyle: AppTypography.labelLarge.copyWith(
                                  fontSize: 15,
                                ),
                              ),
                              child: _signingIn
                                  ? SizedBox.square(
                                      dimension: 22,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2.4,
                                        color: context.palette.textOnAccent,
                                      ),
                                    )
                                  : const Text('Continue with Spotify'),
                            )
                            .animate(delay: 320.ms)
                            .fadeIn()
                            .slideY(begin: 0.3, end: 0),

                        const SizedBox(height: AppSpacing.lg),

                        _LegalNote(onOpenTerms: _openTerms),

                        const SizedBox(height: AppSpacing.lg),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openTerms() async {
    final uri = Uri.parse(AppConstants.spotifyTermsUrl);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && mounted) {
      AppSnackbar.error(context, "Couldn't open the browser.");
    }
  }
}

class _CapabilityRow extends StatelessWidget {
  const _CapabilityRow({required this.icon, required this.text});

  final AurixGlyph icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: context.palette.accentSoft,
              shape: BoxShape.circle,
            ),
            child: AurixIcon(icon, size: 17, color: context.palette.accent),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              text,
              style: AppTypography.bodySmall.copyWith(
                color: context.palette.textSecondary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Required disclaimer.
///
/// AURIX is an independent client. Saying so plainly — and linking Spotify's
/// terms rather than paraphrasing them — is both the honest thing to do and
/// what Spotify's branding guidelines ask of third-party apps.
class _LegalNote extends StatelessWidget {
  const _LegalNote({required this.onOpenTerms});

  final VoidCallback onOpenTerms;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          '${AppConstants.appName} is an independent client and is not '
          'affiliated with or endorsed by Spotify.',
          style: AppTypography.bodySmall.copyWith(
            fontSize: 11,
            color: context.palette.textTertiary,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        TextButton(
          onPressed: onOpenTerms,
          style: TextButton.styleFrom(
            foregroundColor: context.palette.textSecondary,
            minimumSize: const Size(0, 32),
            textStyle: AppTypography.bodySmall.copyWith(
              fontSize: 11,
              decoration: TextDecoration.underline,
            ),
          ),
          child: const Text('Spotify Developer Terms'),
        ),
      ],
    );
  }
}
