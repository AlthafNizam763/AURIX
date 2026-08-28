import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/auth_challenge.dart';
import '../../../data/models/auth_method.dart';
import '../../../data/services/api/api_auth_service.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../providers/auth_provider.dart';
import 'auth_form_field.dart';
import 'provider_mark.dart';
import 'sheet_shell.dart';

/// "That address already has an AURIX account. Is it yours?"
///
/// ## What this sheet is for
///
/// It appears when a social sign-in matched an account that already exists —
/// the provider vouched for an address, and an AURIX account claims the same
/// one. Two facts are established; the missing one is that they belong to the
/// same person.
///
/// It matters that this is *not* presented as an error. Nothing failed, and
/// "sign-in failed, try again" would be actively unhelpful: trying again
/// produces the identical challenge. What it offers instead is the one action
/// that resolves it — prove the account is yours, and the two become one.
///
/// ## Why not link automatically
///
/// Because an AURIX account can claim an address nobody has ever proved they
/// read: registration does not block on the confirmation email. Linking on a
/// name match alone would hand a Google identity — and the library behind it —
/// to whoever registered first with that address. The full argument is in
/// `server/src/services/identities.js`, which is where the decision is
/// enforced; this sheet is the visible half of it.
///
/// ## Two proofs, and why the second one exists
///
/// A password, when the account has one. For an account that was itself
/// created by a social sign-in there is no password to type, and the code sent
/// to the address is the proof — a real one, because delivery is what an
/// address means.
class LinkAccountSheet extends ConsumerStatefulWidget {
  const LinkAccountSheet({required this.challenge, super.key});

  final PendingAccountLink challenge;

  /// Presents the sheet. Resolves true once the accounts have been joined.
  ///
  /// Dismissing it without confirming cancels the pending link on the server
  /// rather than leaving a live challenge naming somebody's account in the
  /// database until its TTL runs out.
  static Future<bool?> show(
    BuildContext context, {
    required PendingAccountLink challenge,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // Not dismissible by a tap outside: the sheet is the only place the
      // token exists, and losing it by brushing the scrim means starting again
      // at the provider's consent screen.
      isDismissible: false,
      enableDrag: false,
      builder: (_) => LinkAccountSheet(challenge: challenge),
    );
  }

  @override
  ConsumerState<LinkAccountSheet> createState() => _LinkAccountSheetState();
}

class _LinkAccountSheetState extends ConsumerState<LinkAccountSheet> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _code = TextEditingController();

  /// Which proof is on screen. Starts on the password when there is one.
  late bool _useCode = !widget.challenge.hasPassword;

  bool _busy = false;
  bool _obscure = true;
  String? _error;
  LinkCodeSent? _sent;

  @override
  void initState() {
    super.initState();
    // An account with no password has exactly one way through this sheet, so
    // the code is sent without making the user ask for it.
    if (_useCode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendCode());
    }
  }

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _useCode = true;
    });

    try {
      final sent = await ref
          .read(authControllerProvider.notifier)
          .sendAccountLinkCode(widget.challenge.token);
      if (!mounted) return;
      setState(() {
        _sent = sent;
        _busy = false;
      });
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.message;
        // Fall back to the password when there is one, so a mail transport
        // that is down does not strand an account that could have confirmed
        // another way.
        _useCode = !widget.challenge.hasPassword;
      });
    }
  }

  Future<void> _confirm() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .confirmAccountLink(
            linkToken: widget.challenge.token,
            password: _useCode ? null : _password.text,
            code: _useCode ? _code.text : null,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.message;
      });

      // The server destroys the challenge after a handful of wrong answers, so
      // there is nothing left to try against. Closing the sheet is the honest
      // response — the flow restarts at the provider.
      if (failure.kind == AuthFailureKind.linkExpired) {
        Navigator.of(context).pop(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final challenge = widget.challenge;
    final provider = challenge.provider;

    return Form(
      key: _formKey,
      child: SheetShell(
        leading: provider == null
            ? null
            : _LinkGlyph(provider: provider, palette: palette),
        title: 'That account already exists',
        subtitle:
            'An AURIX account already uses ${challenge.maskedEmail}, which is '
            'the address ${challenge.providerLabel} just confirmed. Prove it is '
            'yours and we will add ${challenge.providerLabel} to it instead of '
            'creating a second account.',
        children: [
          if (challenge.existingMethods.isNotEmpty) ...[
            _UsualMethods(methods: challenge.existingMethods),
            const SizedBox(height: AppSpacing.lg),
          ],

          if (_useCode) ...[
            AuthFormField(
              controller: _code,
              label: 'Confirmation code',
              hint: '••••••',
              icon: AurixGlyph.lock,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.oneTimeCode],
              enabled: !_busy,
              onSubmitted: (_) => _confirm(),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Enter the code we sent you.'
                  : null,
            ),
            if (_sent != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Sent to ${_sent!.destination}.',
                style: AppTypography.bodySmall.copyWith(
                  color: palette.textSecondary,
                ),
              ),
            ],
          ] else
            AuthFormField(
              controller: _password,
              label: 'AURIX password',
              hint: 'The password on that account',
              icon: AurixGlyph.lock,
              obscureText: _obscure,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              enabled: !_busy,
              onSubmitted: (_) => _confirm(),
              validator: (value) =>
                  (value ?? '').isEmpty ? 'Enter the account password.' : null,
              trailing: IconButton(
                onPressed: () => setState(() => _obscure = !_obscure),
                icon: AurixIcon(
                  _obscure ? AurixGlyph.sun : AurixGlyph.moon,
                  size: 18,
                  color: palette.textSecondary,
                ),
                tooltip: _obscure ? 'Show password' : 'Hide password',
              ),
            ),

          const SizedBox(height: AppSpacing.xl),
          SheetError(_error),

          FilledButton(
            onPressed: _busy ? null : _confirm,
            style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
            child: _busy
                ? SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.2,
                      color: palette.textOnAccent,
                    ),
                  )
                : Text('Link ${challenge.providerLabel}'),
          ),

          const SizedBox(height: AppSpacing.sm),

          // The alternative proof. Offered only when both exist — an account
          // with no password has nothing to switch to, and a switch that led
          // back to an empty field would be a dead end.
          if (challenge.hasPassword)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      if (_useCode) {
                        setState(() {
                          _useCode = false;
                          _error = null;
                        });
                      } else {
                        _sendCode();
                      }
                    },
              style: TextButton.styleFrom(foregroundColor: palette.textSecondary),
              child: Text(
                _useCode
                    ? 'Use the account password instead'
                    : 'Email me a code instead',
              ),
            ),

          TextButton(
            onPressed: _busy ? null : _decline,
            style: TextButton.styleFrom(foregroundColor: palette.textTertiary),
            child: const Text('That is not my account'),
          ),
        ],
      ),
    );
  }

  /// Abandons the link — "no, that is not my account".
  ///
  /// Tells the server, rather than relying on the ten-minute expiry. A live
  /// challenge naming a stranger's account is not something to leave lying
  /// around because the user was in a hurry.
  Future<void> _decline() async {
    await ref
        .read(authControllerProvider.notifier)
        .cancelAccountLink(widget.challenge.token);
    if (!mounted) return;
    Navigator.of(context).pop(false);
  }
}

/// The provider being linked in, shown above the title.
///
/// A mark rather than a generic padlock, because the first question the user
/// has is "which of those buttons did I just press?" — and the answer being
/// visible is what makes the rest of the sheet make sense.
class _LinkGlyph extends StatelessWidget {
  const _LinkGlyph({required this.provider, required this.palette});

  final AuthMethod provider;
  final AurixPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: palette.glassFill,
        shape: BoxShape.circle,
        border: Border.all(color: palette.hairline),
      ),
      child: Center(child: ProviderMark(provider, size: 26)),
    );
  }
}

/// "You normally sign in with Email or Google."
///
/// The sentence that turns an abstract challenge into something recognisable.
/// Somebody who has forgotten they ever made an AURIX account will remember
/// how they made it, and being told is what stops this reading as a phishing
/// prompt.
class _UsualMethods extends StatelessWidget {
  const _UsualMethods({required this.methods});

  final List<AuthMethod> methods;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final names = methods.map((method) => method.label).toList();
    final joined = names.length == 1
        ? names.single
        : '${names.take(names.length - 1).join(', ')} or ${names.last}';

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: palette.glassFill,
        borderRadius: AppRadius.card,
        border: Border.all(color: palette.hairline),
      ),
      child: Row(
        children: [
          for (final method in methods) ...[
            ProviderMark(method, size: 18),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Text(
              'That account signs in with $joined.',
              style: AppTypography.bodySmall.copyWith(
                color: palette.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
