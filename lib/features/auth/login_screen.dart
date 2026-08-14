import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import 'widgets/auth_form_field.dart';
import 'widgets/forgot_password_sheet.dart';

/// Which half of the screen the user is on.
enum _Mode {
  signIn,
  register;

  bool get isRegister => this == _Mode.register;
}

/// Sign in to AURIX, or create an account.
///
/// ## What changed, and why it is one screen
///
/// This used to be a single "Continue with Spotify" button: AURIX had no
/// accounts of its own, so signing in *was* connecting a Spotify account. AURIX
/// now has its own identity in Firebase Authentication, and Spotify is an
/// optional import you reach from Settings after signing in — so this screen
/// asks for an email and a password and mentions Spotify nowhere.
///
/// Sign-in and registration share one screen rather than living behind separate
/// routes. They differ by exactly one field, and a user who taps the wrong one
/// should not lose what they have typed getting to the other — the email and
/// password controllers survive the switch.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  _Mode _mode = _Mode.signIn;
  bool _busy = false;
  bool _obscure = true;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  void _switchMode() {
    setState(() {
      _mode = _mode.isRegister ? _Mode.signIn : _Mode.register;
    });
    // A stale "that email is already registered" belongs to the mode the user
    // just left.
    ref.read(authControllerProvider.notifier).clearError();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    final controller = ref.read(authControllerProvider.notifier);
    final success = _mode.isRegister
        ? await controller.register(
            email: _email.text,
            password: _password.text,
            name: _name.text,
          )
        : await controller.signIn(email: _email.text, password: _password.text);

    if (!mounted) return;
    setState(() => _busy = false);

    if (!success) {
      final message = ref.read(authControllerProvider).errorMessage;
      if (message != null) AppSnackbar.error(context, message);
      return;
    }
    // On success the router's redirect takes over; navigating here too would
    // race it.
  }

  Future<void> _forgotPassword() async {
    final sent = await ForgotPasswordSheet.show(
      context,
      initialEmail: _email.text,
    );
    if (sent == true && mounted) {
      AppSnackbar.success(
        context,
        'If that address has an AURIX account, a reset link is on its way.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = context.isLandscape;
    final isRegister = _mode.isRegister;

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
                    child: Form(
                      key: _formKey,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: isLandscape ? AppSpacing.md : AppSpacing.xxl,
                          ),

                          Center(
                            child: const AurixLogoBadge(size: 88)
                                .animate()
                                .fadeIn(duration: 520.ms)
                                .scale(
                                  begin: const Offset(0.86, 0.86),
                                  curve: Curves.easeOutBack,
                                ),
                          ),

                          const SizedBox(height: AppSpacing.xxl),

                          Text(
                                isRegister
                                    ? 'Create your\nAURIX account.'
                                    : 'Your music,\nbeautifully arranged.',
                                style: AppTypography.displaySmall,
                                textAlign: TextAlign.center,
                              )
                              .animate(delay: 140.ms)
                              .fadeIn()
                              .slideY(begin: 0.2, end: 0),

                          const SizedBox(height: AppSpacing.sm),

                          Text(
                            isRegister
                                ? 'Playlists, liked songs and listening history, '
                                      'synced to every device you sign in on.'
                                : 'Sign in to pick up where you left off.',
                            style: AppTypography.bodyMedium,
                            textAlign: TextAlign.center,
                          ).animate(delay: 220.ms).fadeIn(),

                          const SizedBox(height: AppSpacing.xxl),

                          // Only present when registering. Kept outside the
                          // AnimatedSize's child list rather than merely hidden,
                          // so an empty name field can never be submitted with
                          // the sign-in form.
                          AnimatedSize(
                            duration: AppConstants.medium,
                            curve: Curves.easeOutCubic,
                            alignment: Alignment.topCenter,
                            child: isRegister
                                ? Column(
                                    children: [
                                      AuthFormField(
                                        controller: _name,
                                        label: 'Name',
                                        hint: 'What should we call you?',
                                        icon: AurixGlyph.profile,
                                        textInputAction: TextInputAction.next,
                                        autofillHints: const [AutofillHints.name],
                                        onSubmitted: (_) =>
                                            _emailFocus.requestFocus(),
                                        validator: _validateName,
                                      ),
                                      const SizedBox(height: AppSpacing.md),
                                    ],
                                  )
                                : const SizedBox(width: double.infinity),
                          ),

                          AuthFormField(
                            controller: _email,
                            focusNode: _emailFocus,
                            label: 'Email',
                            hint: 'you@example.com',
                            icon: AurixGlyph.info,
                            keyboardType: TextInputType.emailAddress,
                            textInputAction: TextInputAction.next,
                            autofillHints: const [AutofillHints.email],
                            onSubmitted: (_) => _passwordFocus.requestFocus(),
                            validator: _validateEmail,
                          ),

                          const SizedBox(height: AppSpacing.md),

                          AuthFormField(
                            controller: _password,
                            focusNode: _passwordFocus,
                            label: 'Password',
                            hint: isRegister
                                ? 'At least 6 characters'
                                : 'Your password',
                            icon: AurixGlyph.lock,
                            obscureText: _obscure,
                            textInputAction: TextInputAction.done,
                            autofillHints: [
                              isRegister
                                  ? AutofillHints.newPassword
                                  : AutofillHints.password,
                            ],
                            onSubmitted: (_) => _submit(),
                            validator: _validatePassword,
                            trailing: IconButton(
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: AurixIcon(
                                _obscure ? AurixGlyph.sun : AurixGlyph.moon,
                                size: 18,
                                color: context.palette.textSecondary,
                              ),
                              tooltip: _obscure
                                  ? 'Show password'
                                  : 'Hide password',
                            ),
                          ),

                          if (!isRegister) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton(
                                onPressed: _busy ? null : _forgotPassword,
                                style: TextButton.styleFrom(
                                  foregroundColor: context.palette.textSecondary,
                                  minimumSize: const Size(0, 36),
                                ),
                                child: const Text('Forgot password?'),
                              ),
                            ),
                          ],

                          const Spacer(),
                          const SizedBox(height: AppSpacing.xl),

                          FilledButton(
                                onPressed: _busy ? null : _submit,
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 54),
                                  textStyle: AppTypography.labelLarge.copyWith(
                                    fontSize: 15,
                                  ),
                                ),
                                child: _busy
                                    ? SizedBox.square(
                                        dimension: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: context.palette.textOnAccent,
                                        ),
                                      )
                                    : Text(
                                        isRegister
                                            ? 'Create account'
                                            : 'Sign in',
                                      ),
                              )
                              .animate(delay: 320.ms)
                              .fadeIn()
                              .slideY(begin: 0.3, end: 0),

                          const SizedBox(height: AppSpacing.md),

                          _ModeSwitch(
                            isRegister: isRegister,
                            onPressed: _busy ? null : _switchMode,
                          ),

                          const SizedBox(height: AppSpacing.lg),

                          const _IndependenceNote(),

                          const SizedBox(height: AppSpacing.md),
                        ],
                      ),
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

  // ---- Validation ---------------------------------------------------------
  //
  // Client-side validation here is a courtesy, not a control. Firebase enforces
  // the real rules, and its answers are what the user is shown when these pass
  // and the request still fails. The point of these is to catch the obvious
  // cases without a round trip.

  String? _validateName(String? value) {
    if (!_mode.isRegister) return null;
    if ((value ?? '').trim().isEmpty) return 'Tell us what to call you.';
    return null;
  }

  String? _validateEmail(String? value) {
    final email = (value ?? '').trim();
    if (email.isEmpty) return 'Enter your email address.';
    // Deliberately permissive. A stricter pattern rejects addresses that are
    // perfectly valid — plus-tags, new TLDs, non-ASCII locals — and the only
    // authority on whether an address works is the mail that arrives at it.
    if (!email.contains('@') || email.startsWith('@') || email.endsWith('@')) {
      return 'That does not look like an email address.';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    final password = value ?? '';
    if (password.isEmpty) return 'Enter your password.';
    // Only checked when registering: an existing account may predate this rule,
    // and refusing to *submit* a correct password because it is short would
    // lock its owner out of their own library.
    if (_mode.isRegister && password.length < 6) {
      return 'Use at least 6 characters.';
    }
    return null;
  }
}

class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.isRegister, required this.onPressed});

  final bool isRegister;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    // A Wrap, not a Row.
    //
    // "Already have an account?" beside "Sign in" is comfortably over 300
    // logical pixels, and a Row overflows rather than wrapping — which on a
    // 320pt screen put the button partly off the edge and made it untappable.
    // A Wrap lays the two out side by side where there is room and stacks them
    // where there is not.
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          isRegister ? 'Already have an account?' : 'New to AURIX?',
          style: AppTypography.bodySmall.copyWith(
            color: context.palette.textSecondary,
          ),
        ),
        TextButton(
          onPressed: onPressed,
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 36),
            textStyle: AppTypography.labelLarge.copyWith(fontSize: 13),
          ),
          child: Text(isRegister ? 'Sign in' : 'Create an account'),
        ),
      ],
    );
  }
}

/// AURIX is its own application.
///
/// The old note here disclaimed affiliation with Spotify and linked Spotify's
/// developer terms, because signing in *was* a Spotify authorization. Nothing
/// on this screen touches Spotify any more, so the disclaimer has moved to
/// where a Spotify authorization actually happens — the import screen — and
/// what is left is a plain statement of where the account lives.
class _IndependenceNote extends StatelessWidget {
  const _IndependenceNote();

  @override
  Widget build(BuildContext context) {
    return Text(
      'Your ${AppConstants.appName} account is independent. Music you import '
      'from another service stays linked to that service for playback.',
      style: AppTypography.bodySmall.copyWith(
        fontSize: 11,
        color: context.palette.textTertiary,
        height: 1.5,
      ),
      textAlign: TextAlign.center,
    );
  }
}
