import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../providers/auth_provider.dart';
import 'auth_form_field.dart';

/// Asks for an email address and sends a Firebase password-reset link to it.
///
/// ## Why it never says whether the account exists
///
/// The result is the same sentence whether or not the address is registered:
/// *"if that address has an AURIX account, a reset link is on its way."*
///
/// That is not vagueness for its own sake. A reset form that answers "no
/// account with that email" is an unauthenticated oracle for whether a given
/// person has an account here, testable at whatever rate the network allows.
/// Firebase's own `sendPasswordResetEmail` is configured to behave the same
/// way, and [ApiAuthService.sendPasswordResetEmail] swallows the
/// `user-not-found` case for builds where it is not.
///
/// The cost is that a typo looks like success. That is the accepted trade —
/// the mail not arriving is the feedback, and it is one the attacker cannot
/// see.
class ForgotPasswordSheet extends ConsumerStatefulWidget {
  const ForgotPasswordSheet({super.key, this.initialEmail = ''});

  final String initialEmail;

  /// Presents the sheet. Resolves true once a reset has been requested.
  static Future<bool?> show(BuildContext context, {String initialEmail = ''}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ForgotPasswordSheet(initialEmail: initialEmail),
    );
  }

  @override
  ConsumerState<ForgotPasswordSheet> createState() =>
      _ForgotPasswordSheetState();
}

class _ForgotPasswordSheetState extends ConsumerState<ForgotPasswordSheet> {
  late final TextEditingController _email = TextEditingController(
    text: widget.initialEmail.trim(),
  );
  final _formKey = GlobalKey<FormState>();
  bool _busy = false;

  @override
  void dispose() {
    _email.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    final error = await ref
        .read(authControllerProvider.notifier)
        .sendPasswordReset(_email.text);

    if (!mounted) return;
    setState(() => _busy = false);

    if (error != null) {
      AppSnackbar.error(context, error);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      // Lifts the sheet clear of the keyboard it summons.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: AppRadius.sheet,
        ),
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.xl,
          AppSpacing.md,
          AppSpacing.xl,
          AppSpacing.xl,
        ),
        child: SafeArea(
          top: false,
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: context.palette.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),

                const Text('Reset your password', style: AppTypography.headlineSmall),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  'We will email you a link to choose a new one.',
                  style: AppTypography.bodySmall.copyWith(
                    color: context.palette.textSecondary,
                  ),
                ),

                const SizedBox(height: AppSpacing.xl),

                AuthFormField(
                  controller: _email,
                  label: 'Email',
                  hint: 'you@example.com',
                  icon: AurixGlyph.info,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.email],
                  enabled: !_busy,
                  onSubmitted: (_) => _send(),
                  validator: (value) {
                    final email = (value ?? '').trim();
                    if (email.isEmpty) return 'Enter your email address.';
                    if (!email.contains('@')) {
                      return 'That does not look like an email address.';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: AppSpacing.xl),

                FilledButton(
                  onPressed: _busy ? null : _send,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 50),
                  ),
                  child: _busy
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: context.palette.textOnAccent,
                          ),
                        )
                      : const Text('Send reset link'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
