import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  const ChangePasswordSheet({super.key});

  static Future<bool?> show(BuildContext context) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const ChangePasswordSheet(),
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
          currentPassword: _current.text,
          newPassword: _next.text,
        );

    if (!mounted) return;
    setState(() => _busy = false);

    if (error != null) {
      AppSnackbar.error(context, error);
      return;
    }

    Navigator.of(context).pop(true);
    AppSnackbar.success(context, 'Password changed');
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

                const Text('Change password', style: AppTypography.headlineSmall),
                const SizedBox(height: AppSpacing.xl),

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

                AuthFormField(
                  controller: _next,
                  label: 'New password',
                  hint: 'At least 6 characters',
                  icon: AurixGlyph.lock,
                  obscureText: true,
                  enabled: !_busy,
                  textInputAction: TextInputAction.done,
                  autofillHints: const [AutofillHints.newPassword],
                  onSubmitted: (_) => _submit(),
                  validator: (value) {
                    final password = value ?? '';
                    if (password.length < 6) return 'Use at least 6 characters.';
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
                      : const Text('Change password'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
