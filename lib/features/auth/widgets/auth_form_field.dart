import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// One labelled field on the auth screens.
///
/// A wrapper rather than a raw [TextFormField] because the three fields on the
/// sign-in screen, the two on the password sheet and the one on the reset form
/// all need the same six decisions made the same way — label above the box, the
/// app's glyph set rather than Material icons, no autocorrect or capitalisation
/// on anything typed into a credential field. Repeating those at seven call
/// sites is how one of them ends up autocapitalising an email address.
class AuthFormField extends StatelessWidget {
  const AuthFormField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.icon,
    this.focusNode,
    this.keyboardType,
    this.textInputAction,
    this.obscureText = false,
    this.autofillHints,
    this.validator,
    this.onSubmitted,
    this.trailing,
    this.enabled = true,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final AurixGlyph? icon;
  final FocusNode? focusNode;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool obscureText;
  final List<String>? autofillHints;
  final String? Function(String?)? validator;
  final ValueChanged<String>? onSubmitted;

  /// Usually a visibility toggle. Rendered as the field's suffix.
  final Widget? trailing;

  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.xs,
            bottom: AppSpacing.xs,
          ),
          child: Text(
            label,
            style: AppTypography.labelMedium.copyWith(
              color: context.palette.textSecondary,
            ),
          ),
        ),
        TextFormField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          obscureText: obscureText,
          autofillHints: autofillHints,
          validator: validator,
          onFieldSubmitted: onSubmitted,
          style: AppTypography.bodyMedium.copyWith(
            color: context.palette.textPrimary,
          ),
          // Off for every field this widget builds. All of them hold a
          // credential or an address, and a keyboard that "corrects" an email
          // domain or capitalises the first letter of a password produces a
          // value the user did not type and cannot see through the dots.
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          // Newlines have no meaning in any of these and would silently pass
          // validation on a pasted value.
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.deny(RegExp(r'\n')),
          ],
          decoration: InputDecoration(
            hintText: hint,
            prefixIcon: icon == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.md,
                      right: AppSpacing.sm,
                    ),
                    child: AurixIcon(
                      icon!,
                      size: 18,
                      color: context.palette.textSecondary,
                    ),
                  ),
            prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
            suffixIcon: trailing,
            errorStyle: AppTypography.bodySmall.copyWith(
              color: context.palette.accent,
              fontSize: 11,
            ),
          ),
        ),
      ],
    );
  }
}
