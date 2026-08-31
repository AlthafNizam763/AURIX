import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// The chrome every auth sheet shares: surface, grab handle, title, keyboard
/// inset and safe area.
///
/// Extracted when the phone and account-link sheets arrived and the same
/// twenty lines were about to be written a third and fourth time. Four of the
/// decisions in it are easy to get subtly wrong on one sheet and not another:
///
///  * the `viewInsets` padding, without which the keyboard covers the field
///    that summoned it;
///  * `SafeArea(top: false)`, because a bottom sheet has no top inset to
///    respect and applying one leaves a gap under the handle;
///  * `mainAxisSize: min`, so the sheet is as tall as its content rather than
///    as tall as the screen;
///  * a scroll view around the content, so a sheet that *is* taller than the
///    space left above the keyboard scrolls instead of overflowing.
///
/// The existing password sheets predate this and still inline their own copy.
/// They are left alone deliberately — this change is about adding sign-in
/// methods, and rewriting two working screens to share a wrapper is a separate
/// piece of work with its own risk.
class SheetShell extends StatelessWidget {
  const SheetShell({
    required this.title,
    required this.children,
    this.subtitle,
    this.leading,
    super.key,
  });

  final String title;
  final String? subtitle;

  /// Drawn above the title — a provider mark on the account-link sheet.
  final Widget? leading;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        decoration: BoxDecoration(
          color: palette.surface,
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
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: palette.hairline,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),

                if (leading != null) ...[
                  Center(child: leading!),
                  const SizedBox(height: AppSpacing.lg),
                ],

                Text(title, style: AppTypography.headlineSmall),

                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    subtitle!,
                    style: AppTypography.bodySmall.copyWith(
                      color: palette.textSecondary,
                    ),
                  ),
                ],

                const SizedBox(height: AppSpacing.xl),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The inline status line the auth sheets show under their fields.
///
/// A line in the sheet rather than a snackbar, because every message it carries
/// is about something happening *here* — a code that just went out, a wrong
/// code, a number with no country code — and a snackbar takes that away after
/// four seconds and possibly from behind the keyboard.
///
/// One widget for both tones rather than two, so a sheet cannot end up showing
/// a stale success line above a fresh error: there is one slot, and whatever
/// is in it is the current state.
class SheetError extends StatelessWidget {
  const SheetError(this.message, {super.key}) : isSuccess = false;

  /// A confirmation — "OTP sent successfully". Same slot, calmer colour.
  const SheetError.success(this.message, {super.key}) : isSuccess = true;

  final String? message;

  /// True for a confirmation, false for a fault. Not an enum, because a
  /// private enum on a public field is one the callers cannot name.
  final bool isSuccess;

  @override
  Widget build(BuildContext context) {
    if (message == null || message!.isEmpty) return const SizedBox.shrink();
    final palette = context.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AurixIcon(
            isSuccess ? AurixGlyph.checkCircle : AurixGlyph.warning,
            size: 16,
            color: isSuccess ? palette.textSecondary : palette.attention,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              message!,
              style: AppTypography.bodySmall.copyWith(
                color: isSuccess ? palette.textSecondary : palette.attention,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
