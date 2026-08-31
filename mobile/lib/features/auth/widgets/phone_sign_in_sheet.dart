import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/auth_challenge.dart';
import '../../../data/services/api/api_auth_service.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../providers/auth_provider.dart';
import 'auth_form_field.dart';
import 'sheet_shell.dart';

/// Sign in with a phone number, or attach one to the account already open.
///
/// ## Two steps in one sheet
///
/// The number and the code are separate screens conceptually and one sheet in
/// practice, because the second is meaningless without the first and because
/// the user has to be able to go back and fix a typo without losing the flow.
/// Going back is what [_editNumber] does, and it deliberately abandons the code
/// that was sent rather than trying to reuse it — the server keys the live code
/// on the number, so a corrected number needs a new one anyway.
///
/// ## The countdown is the server's, not ours
///
/// [_resendIn] starts from the value the API returned, because the API is what
/// enforces it. A countdown drawn from a constant here would eventually
/// disagree with the only clock that decides anything, and the user would tap
/// Resend to be told to wait.
///
/// ## Where the code comes from
///
/// A handset, and only a handset. The API generates it, sends it over SMS, and
/// returns timings and a masked number — never the code itself, in any
/// environment. There is nothing in this sheet, in [PhoneCodeRequest], or in
/// the service beneath it that could display or log one, because the value
/// never crosses the network. A deployment with no SMS provider does not offer
/// phone sign-in at all, so this sheet is unreachable there.
class PhoneSignInSheet extends ConsumerStatefulWidget {
  const PhoneSignInSheet({this.linkToCurrentAccount = false, super.key});

  /// Attach the number to the signed-in account instead of signing in with it.
  final bool linkToCurrentAccount;

  /// Presents the sheet. Resolves true once the flow has completed.
  static Future<bool?> show(
    BuildContext context, {
    bool linkToCurrentAccount = false,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => PhoneSignInSheet(linkToCurrentAccount: linkToCurrentAccount),
    );
  }

  @override
  ConsumerState<PhoneSignInSheet> createState() => _PhoneSignInSheetState();
}

class _PhoneSignInSheetState extends ConsumerState<PhoneSignInSheet> {
  final _formKey = GlobalKey<FormState>();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _name = TextEditingController();
  final _codeFocus = FocusNode();

  /// Null until a code has been sent. Non-null is the second step.
  PhoneCodeRequest? _sent;

  bool _busy = false;
  String? _error;

  /// The confirmation shown after a code goes out, cleared by anything else.
  ///
  /// Worth saying explicitly rather than letting the step change imply it: the
  /// user has just been asked to leave the app, check a message and come back,
  /// and "OTP sent successfully" is what tells them the waiting is expected
  /// rather than a stall. It is also the only positive feedback in the flow —
  /// there is no code on screen to look at.
  String? _notice;

  int _resendIn = 0;
  Timer? _countdown;

  @override
  void dispose() {
    _countdown?.cancel();
    _phone.dispose();
    _code.dispose();
    _name.dispose();
    _codeFocus.dispose();
    super.dispose();
  }

  void _startCountdown(Duration from) {
    _countdown?.cancel();
    setState(() => _resendIn = from.inSeconds);
    _countdown = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      setState(() => _resendIn -= 1);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  Future<void> _sendCode() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });

    try {
      final request = await ref
          .read(authControllerProvider.notifier)
          .sendPhoneCode(
            _phone.text,
            linkToCurrentAccount: widget.linkToCurrentAccount,
          );
      if (!mounted) return;
      setState(() {
        _sent = request;
        _busy = false;
        _notice = 'OTP sent successfully';
      });
      _startCountdown(request.resendIn);
      _codeFocus.requestFocus();
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.message;
      });
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      // The confirmation has done its job; a wrong code below must not appear
      // underneath a line still saying the send worked.
      _notice = null;
    });

    try {
      if (widget.linkToCurrentAccount) {
        await ref
            .read(authControllerProvider.notifier)
            .linkPhone(phone: _phone.text, code: _code.text);
      } else {
        await ref
            .read(authControllerProvider.notifier)
            .verifyPhoneCode(
              phone: _phone.text,
              code: _code.text,
              name: _name.text,
            );
      }
      if (!mounted) return;
      // On a sign-in the router's redirect takes over from here; popping is
      // what gets the sheet out of its way.
      Navigator.of(context).pop(true);
    } on AuthFailure catch (failure) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = failure.message;
      });
      // A burned or expired code cannot be retyped into a working state, so
      // the sheet returns to the number rather than leaving the user tapping
      // Verify against something that will never succeed.
      if (failure.kind == AuthFailureKind.codeExpired) _editNumber();
    }
  }

  void _editNumber() {
    _countdown?.cancel();
    _code.clear();
    setState(() {
      _sent = null;
      _resendIn = 0;
      _notice = null;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final sent = _sent;
    final linking = widget.linkToCurrentAccount;

    return Form(
      key: _formKey,
      child: SheetShell(
        title: sent == null
            ? (linking ? 'Add your phone number' : 'Sign in with your phone')
            : 'Enter the code',
        subtitle: sent == null
            ? (linking
                  ? 'You will be able to sign in with this number as well as '
                        'the way you use now.'
                  : 'We will text you a code. Include your country code.')
            : 'Sent to ${sent.maskedPhone}.',
        children: [
          if (sent == null) ...[
            AuthFormField(
              controller: _phone,
              label: 'Phone number',
              hint: '+44 7700 900123',
              icon: AurixGlyph.phone,
              keyboardType: TextInputType.phone,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.telephoneNumber],
              enabled: !_busy,
              onSubmitted: (_) => _sendCode(),
              validator: _validatePhone,
            ),
            const SizedBox(height: AppSpacing.xl),
            SheetError(_error),
            _PrimaryAction(
              label: 'Send code',
              busy: _busy,
              onPressed: _busy ? null : _sendCode,
            ),
          ] else ...[
            AuthFormField(
              controller: _code,
              focusNode: _codeFocus,
              label: 'Code',
              hint: '••••••',
              icon: AurixGlyph.lock,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.done,
              // The platform reads the code out of the incoming SMS and offers
              // it above the keyboard, which removes the whole
              // leave-the-app-and-come-back problem this flow otherwise has.
              autofillHints: const [AutofillHints.oneTimeCode],
              enabled: !_busy,
              onSubmitted: (_) => _verify(),
              validator: _validateCode,
            ),

            // Offered only when creating an account, and only as a courtesy —
            // an account made from a phone number has no name until somebody
            // gives it one, and asking here is cheaper than a profile prompt
            // on first launch. Skipping it is fine: `displayName` falls back
            // to the last four digits.
            if (!linking) ...[
              const SizedBox(height: AppSpacing.md),
              AuthFormField(
                controller: _name,
                label: 'Name (optional)',
                hint: 'What should we call you?',
                icon: AurixGlyph.profile,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.name],
                enabled: !_busy,
                onSubmitted: (_) => _verify(),
              ),
            ],

            const SizedBox(height: AppSpacing.xl),

            // One slot, so a stale confirmation can never sit above a fresh
            // fault. The error wins whenever both could apply.
            if (_error != null)
              SheetError(_error)
            else
              SheetError.success(_notice),

            _PrimaryAction(
              label: linking ? 'Add number' : 'Verify and continue',
              busy: _busy,
              onPressed: _busy ? null : _verify,
            ),

            const SizedBox(height: AppSpacing.sm),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _busy ? null : _editNumber,
                  style: TextButton.styleFrom(
                    foregroundColor: palette.textSecondary,
                  ),
                  child: const Text('Change number'),
                ),
                TextButton(
                  onPressed: _busy || _resendIn > 0 ? null : _sendCode,
                  style: TextButton.styleFrom(
                    foregroundColor: palette.textSecondary,
                  ),
                  child: Text(_resendIn > 0 ? 'Resend in ${_resendIn}s' : 'Resend'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---- Validation ---------------------------------------------------------
  //
  // Both checks are courtesies. The API normalises the number and decides
  // whether the code is right, and its answers are what the user is shown when
  // these pass and the request still fails. The point of having them is to
  // catch the obvious case without a round trip and, for the number, without
  // spending one of the five texts an hour the server will send.

  String? _validatePhone(String? value) {
    if (_sent != null) return null;
    final phone = (value ?? '').trim();
    if (phone.isEmpty) return 'Enter your phone number.';
    final digits = phone.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length < 7) return 'That is too short to be a phone number.';
    return null;
  }

  String? _validateCode(String? value) {
    if (_sent == null) return null;
    final code = (value ?? '').trim();
    if (code.isEmpty) return 'Enter the code we sent you.';
    // Length is deliberately not asserted: `OTP_LENGTH` is the server's to
    // choose, and a client that insisted on six would refuse a valid code the
    // moment a deployment changed it.
    if (!RegExp(r'^\d+$').hasMatch(code)) return 'The code is digits only.';
    return null;
  }
}

/// The sheet's one filled button, with its busy state.
class _PrimaryAction extends StatelessWidget {
  const _PrimaryAction({
    required this.label,
    required this.busy,
    required this.onPressed,
  });

  final String label;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(minimumSize: const Size(0, 50)),
      child: busy
          ? SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: context.palette.textOnAccent,
              ),
            )
          : Text(label),
    );
  }
}
