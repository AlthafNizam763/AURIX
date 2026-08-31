import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/auth_method.dart';
import 'provider_mark.dart';

/// One sign-in option: a mark and a name.
///
/// ## Why the label is centred and the mark is not
///
/// The obvious layout — a `Row` of mark, gap, label — puts the text in a
/// different place on every button, because the marks are different widths and
/// the words are different lengths. Stacked five deep that reads as five
/// unrelated controls.
///
/// So the mark is positioned against the leading edge and the label is centred
/// in the *button*, independently. The five labels then share a centre line and
/// the five marks share a left margin, which is what makes the group read as
/// one list of equivalent choices — which is exactly what it is.
///
/// That alignment matters more since the labels became bare provider names.
/// "Continue with Facebook" and "Continue with Apple" were near enough the same
/// width to look tidy however they were laid out; "Facebook" and "Apple" are
/// not, and a leading-aligned version of this would visibly stagger.
///
/// ## Neutral, not branded
///
/// Every button takes the app's own surface and hairline rather than each
/// provider's brand colour. A column containing a blue Facebook button, a black
/// Apple button and a white Google button is what a login screen looks like
/// when nobody owns the design; it also puts four competing brands above
/// AURIX's own. The mark carries the identification, and one line of colour is
/// enough for that.
class SignInMethodButton extends StatelessWidget {
  const SignInMethodButton({
    required this.method,
    required this.onPressed,
    this.busy = false,
    super.key,
  });

  final AuthMethod method;
  final VoidCallback? onPressed;

  /// Replaces the mark with a spinner while this provider's flow is open.
  ///
  /// Per button rather than per screen: the browser sits on top of the app for
  /// as long as the user takes to consent, and coming back to a screen where
  /// every button is dimmed gives no clue which one was tapped.
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final enabled = onPressed != null && !busy;

    return Semantics(
      button: true,
      // The spoken label, not the drawn one — see [AuthMethod.buttonLabel].
      label: method.signInSemanticLabel,
      child: OutlinedButton(
        onPressed: enabled ? onPressed : null,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 52),
          backgroundColor: palette.glassFill,
          foregroundColor: palette.textPrimary,
          disabledForegroundColor: palette.textTertiary,
          side: BorderSide(color: palette.hairline),
          shape: const RoundedRectangleBorder(borderRadius: AppRadius.card),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          textStyle: AppTypography.labelLarge.copyWith(fontSize: 14),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: SizedBox.square(
                dimension: 24,
                child: Center(
                  child: busy
                      ? SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: palette.textSecondary,
                          ),
                        )
                      // Dimmed rather than hidden when the whole group is
                      // disabled, so the row keeps its shape.
                      : Opacity(
                          opacity: enabled ? 1 : 0.45,
                          child: ProviderMark(method, size: 22),
                        ),
                ),
              ),
            ),
            // Inset past the mark on both sides, so a label that outgrows the
            // space — a long provider name at a large text scale — ellipsises
            // rather than sliding underneath the mark.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Text(
                method.buttonLabel,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
