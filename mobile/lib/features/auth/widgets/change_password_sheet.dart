import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../providers/auth_provider.dart';
import 'auth_form_field.dart';

/// Changes the signed-in account's password.
///
/// ## Why it asks for the current password
///
/// Firebase would accept `updatePassword` on a recent session without one. It
/// is asked for anyway, for two reasons:
///
///  * **An unattended device.** A session persists for months. Without this,
///    anyone holding an unlocked phone can lock its owner out of their account
///    in four taps.
///  * **The alternative failure is worse.** On a session older than Firebase's
///    threshold, `updatePassword` fails with `requires-recent-login` — a dead
///    end the user cannot act on from this screen. Re-authenticating first
///    turns that into "your current password is wrong", which is a question
///    they can answer. See [AuthRepository.updatePassword].
class ChangePasswordSheet extends ConsumerStatefulWidget {
  const ChangePasswordSheet({this.hasExistingPassword = true, super.key});

  /// False for an account that has never had a password — one created by
  /// "Continue with Google" or by a phone code.
  ///
  /// The sheet then asks for one field instead of two and reads as "set a
  /// password", because there is nothing for its owner to type in a *current*
  /// password box and demanding one would leave them unable to add the method
  /// at all. Authorised by holding a live session; the server still demands
  /// the current password wherever one exists, so this cannot become a way to
  /// replace a password without knowing it.
  final bool hasExistingPassword;

  static Future<bool?> show(BuildContext context, {bool hasExistingPassword = true}) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ChangePasswordSheet(hasExistingPassword: hasExistingPassword),
    );
  }

  @override
  ConsumerState<ChangePasswordSheet> createState() =>
      _ChangePasswordSheetState();
}

class _ChangePasswordSheetState extends ConsumerState<ChangePasswordSheet> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _busy = true);
    final error = await ref
        .read(authControllerProvider.notifier)
        .changePassword(
          currentPassword: widget.hasExistingPassword ? _current.text : null,
          newPassword: _next.text,
        );

    if (!mounted) return;
    setState(() => _busy = false);

    if (error != null) {
      AppSnackbar.error(context, error);
      return;
    }

    Navigator.of(context).pop(true);
    AppSnackbar.success(
      context,
      widget.hasExistingPassword ? 'Password changed' : 'Password set',
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
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

                Text(
                  widget.hasExistingPassword ? 'Change password' : 'Set a password',
                  style: AppTypography.headlineSmall,
                ),

                if (!widget.hasExistingPassword) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    'You will be able to sign in with your email and this '
                    'password, as well as the way you use now.',
                    style: AppTypography.bodySmall.copyWith(
                      color: context.palette.textSecondary,
                    ),
                  ),
                ],

                const SizedBox(height: AppSpacing.xl),

                if (widget.hasExistingPassword) ...[
                  AuthFormField(
                    controller: _current,
                    label: 'Current password',
                    icon: AurixGlyph.lock,
                    obscureText: true,
                    enabled: !_busy,
                    textInputAction: TextInputAction.next,
                    autofillHints: const [AutofillHints.password],
                    validator: (value) => (value ?? '').isEmpty
                        ? 'Enter your current password.'
                        : null,
                  ),
                  const SizedBox(height: AppSpacing.md),
                ],

                AuthFormField(
                  controller: _next,
                  label: widget.hasExistingPassword ? 'New password' : 'Password',
                  // Was hard-coded to six, which stopped being true when the
                  // API raised the floor to eight — a hint that promises less
                  // than the validator demands is a form that rejects what it
                  // just said was fine.
                  hint: AppConstants.shortPasswordMessage,
                  icon: AurixGlyph.lock,
                  obscureText: true,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  onSubmitted: (_) => _submit(),
                  validator: (value) {
                    final password = value ?? '';
                    if (password.length < AppConstants.minPasswordLength) {
                      return AppConstants.shortPasswordMessage;
                    }
                    if (password == _current.text) {
                      return 'That is your current password.';
                    }
                    return null;
                  },
                ),

                const SizedBox(height: AppSpacing.xl),

                FilledButton(
                  onPressed: _busy ? null : _submit,
                  style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
                  child: _busy
                      ? SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.2,
                            color: context.palette.textOnAccent,
                          ),
                        )
                      : Text(
                          widget.hasExistingPassword
                              ? 'Change password'
                              : 'Set password',
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
