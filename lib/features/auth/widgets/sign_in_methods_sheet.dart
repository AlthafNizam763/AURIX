import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/aurix_user.dart';
import '../../../data/models/auth_method.dart';
import '../../../data/services/api/api_auth_service.dart';
import '../../../shared/widgets/feedback/app_snackbar.dart';
import '../providers/auth_provider.dart';
import 'change_password_sheet.dart';
import 'phone_sign_in_sheet.dart';
import 'provider_mark.dart';
import 'sheet_shell.dart';

/// Everything attached to this account, and how to attach or detach one.
///
/// ## Why the app needs this screen at all
///
/// Linking has to be reachable from *inside* a session, not only from the
/// login screen. The login screen handles the case where somebody arrives at
/// AURIX through a provider and turns out to already have an account. This
/// handles the other direction, which is at least as common: somebody who has
/// been signing in with a password for a year, on a new phone, about to tap
/// "Continue with Google" — and who would otherwise create the second account
/// this whole feature exists to prevent. Adding Google here first means that
/// tap signs them in instead.
///
/// ## Removing is the dangerous one
///
/// Unlinking is the only account operation in AURIX that can lock its owner out
/// irreversibly: an account with no methods left has no sign-in path *and* no
/// recovery path, because a reset needs an address to send to. The server
/// refuses to remove the last one regardless — see `detachIdentity` — and this
/// screen disables the control and says why, because a button that always fails
/// is worse than no button.
class SignInMethodsSheet extends ConsumerStatefulWidget {
  const SignInMethodsSheet({super.key});

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SignInMethodsSheet(),
    );
  }

  @override
  ConsumerState<SignInMethodsSheet> createState() => _SignInMethodsSheetState();
}

class _SignInMethodsSheetState extends ConsumerState<SignInMethodsSheet> {
  AuthMethod? _busy;

  Future<void> _run(AuthMethod method, Future<void> Function() action) async {
    if (_busy != null) return;
    setState(() => _busy = method);
    try {
      await action();
      if (!mounted) return;
      setState(() => _busy = null);
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() => _busy = null);
      // A dismissed consent screen is a decision, not a failure — the same
      // rule the login screen follows.
      if (failure.kind == AuthFailureKind.cancelled) return;
      AppSnackbar.error(context, failure.message);
    }
  }

  Future<void> _link(AuthMethod method) async {
    switch (method) {
      case AuthMethod.password:
        await ChangePasswordSheet.show(context, hasExistingPassword: false);
        // The account's method list changed on the server; re-read it so the
        // row below flips without waiting for the next launch.
        await ref.read(authControllerProvider.notifier).refreshProfile();
      case AuthMethod.phone:
        await PhoneSignInSheet.show(context, linkToCurrentAccount: true);
      case _:
        await _run(
          method,
          () => ref.read(authControllerProvider.notifier).linkProvider(method),
        );
    }
  }

  Future<void> _unlink(AuthMethod method) async {
    final confirmed = await _confirmRemoval(method);
    if (confirmed != true) return;
    await _run(
      method,
      () => ref.read(authControllerProvider.notifier).unlinkMethod(method),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(currentUserProvider);
    final available = ref.watch(availableAuthMethodsProvider).valueOrNull;

    if (user == null) return const SizedBox.shrink();

    // Everything this deployment can serve, plus anything already on the
    // account. The second half matters: a provider whose credentials were
    // removed from the server after somebody linked it must still be
    // *listed*, or its owner cannot see it and cannot remove it.
    final methods = <AuthMethod>[
      for (final method in AuthMethod.values)
        if ((available ?? const [AuthMethod.password]).contains(method) ||
            user.hasMethod(method))
          method,
    ];

    return SheetShell(
      title: 'Sign-in methods',
      subtitle:
          'Every method below signs in to this one account. Adding one is how '
          'you avoid ending up with a second.',
      children: [
        for (final method in methods)
          _MethodRow(
            method: method,
            linked: user.hasMethod(method),
            // The last method cannot be removed. The server refuses it
            // regardless; this is what explains the refusal before it happens.
            removable: user.hasMethod(method) && !user.hasSingleSignInMethod,
            busy: _busy == method,
            enabled: _busy == null,
            user: user,
            onLink: () => _link(method),
            onUnlink: () => _unlink(method),
          ),
      ],
    );
  }

  Future<bool?> _confirmRemoval(AuthMethod method) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${method.label}?'),
        content: Text(
          'You will no longer be able to sign in to AURIX with '
          '${method.label}. Your library is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Keep it'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(
              foregroundColor: context.palette.attention,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }
}

/// One method: what it is, whether it is attached, and the one control.
class _MethodRow extends StatelessWidget {
  const _MethodRow({
    required this.method,
    required this.linked,
    required this.removable,
    required this.busy,
    required this.enabled,
    required this.user,
    required this.onLink,
    required this.onUnlink,
  });

  final AuthMethod method;
  final bool linked;
  final bool removable;
  final bool busy;
  final bool enabled;
  final AurixUser user;
  final VoidCallback onLink;
  final VoidCallback onUnlink;

  /// What is attached, shown rather than merely asserted.
  ///
  /// "Linked" alone answers the wrong question. The one a user actually has is
  /// *which* Google account, or which number — and an address they do not
  /// recognise is exactly the thing this screen should let them notice.
  String get _detail {
    if (!linked) return 'Not linked';
    return switch (method) {
      AuthMethod.password =>
        user.email.isEmpty ? 'Linked' : 'Sign in as ${user.email}',
      AuthMethod.phone => user.phone.isEmpty ? 'Linked' : user.phone,
      // The provider knows which account; AURIX deliberately does not keep a
      // second copy of a Google address it would then have to keep current.
      _ => 'Linked',
    };
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final isLastMethod = linked && !removable;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 28,
            child: Center(child: ProviderMark(method, size: 22)),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(method.label, style: AppTypography.bodyMedium),
                Text(
                  isLastMethod ? 'Your only way in' : _detail,
                  style: AppTypography.bodySmall.copyWith(
                    color: linked ? palette.textSecondary : palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          if (busy)
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: palette.textSecondary,
              ),
            )
          else if (!linked)
            TextButton(
              onPressed: enabled ? onLink : null,
              child: const Text('Add'),
            )
          else if (removable)
            TextButton(
              onPressed: enabled ? onUnlink : null,
              style: TextButton.styleFrom(foregroundColor: palette.textSecondary),
              child: const Text('Remove'),
            )
          else
            // Disabled rather than absent, so the row still shows where the
            // control would be and the subtitle explains why it is not
            // available. A missing button reads as a bug.
            const TextButton(onPressed: null, child: Text('Remove')),
        ],
      ),
    );
  }
}
