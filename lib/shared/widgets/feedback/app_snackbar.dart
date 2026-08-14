import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

enum SnackTone { neutral, success, warning, error }

/// Toast messages, in one place so they look and behave the same everywhere.
///
/// Always clears any in-flight snackbar first. Queued snackbars are the reason
/// a user who taps "like" five times sees confirmations trickle in ten seconds
/// later, long after the action.
abstract final class AppSnackbar {
  static void show(
    BuildContext context,
    String message, {
    SnackTone tone = SnackTone.neutral,
    String? actionLabel,
    VoidCallback? onAction,
    Duration duration = const Duration(seconds: 3),
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;

    messenger
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          duration: duration,
          content: Row(
            children: [
              // Resolved once and matched on, rather than called twice with a
              // null check between — the second call returned a fresh nullable
              // that the analyser could not narrow.
              ...switch (_iconFor(tone)) {
                null => const <Widget>[],
                final glyph => <Widget>[
                  AurixIcon(glyph, size: 18, color: _colorFor(tone)),
                  const SizedBox(width: AppSpacing.md),
                ],
              },
              Expanded(
                child: Text(
                  message,
                  style: AppTypography.bodyMedium.copyWith(
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          action: actionLabel != null && onAction != null
              ? SnackBarAction(
                  label: actionLabel,
                  onPressed: onAction,
                  textColor: context.palette.accent,
                )
              : null,
        ),
      );
  }

  static void success(BuildContext context, String message) =>
      show(context, message, tone: SnackTone.success);

  static void error(BuildContext context, String message) =>
      show(context, message, tone: SnackTone.error, duration: const Duration(seconds: 4));

  static void warning(BuildContext context, String message) =>
      show(context, message, tone: SnackTone.warning);

  /// Confirms an action and offers to reverse it. Used for library writes,
  /// where an accidental unsave is otherwise silent and irreversible from
  /// where the user is standing.
  static void undoable(
    BuildContext context,
    String message, {
    required VoidCallback onUndo,
  }) => show(
    context,
    message,
    tone: SnackTone.success,
    actionLabel: 'Undo',
    onAction: onUndo,
    duration: const Duration(seconds: 5),
  );

  static AurixGlyph? _iconFor(SnackTone tone) {
    switch (tone) {
      case SnackTone.neutral:
        return null;
      case SnackTone.success:
        return AurixGlyph.checkCircle;
      case SnackTone.warning:
        return AurixGlyph.warning;
      case SnackTone.error:
        return AurixGlyph.warning;
    }
  }

  static Color _colorFor(SnackTone tone) {
    switch (tone) {
      case SnackTone.neutral:
        return AppColors.textSecondary;
      case SnackTone.success:
        // Deliberately AppColors.success, not the brand accent. Now that the
        // accent is red, "Saved to your library" would otherwise read as an
        // error.
        return AppColors.success;
      case SnackTone.warning:
        return AppColors.warning;
      case SnackTone.error:
        return AppColors.error;
    }
  }
}
