import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../media/app_artwork.dart';

/// One row in a context sheet.
class SheetAction {
  const SheetAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
    this.destructive = false,
    this.enabled = true,
    this.trailing,
    this.iconColor,
  });

  final AurixGlyph icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  /// Tints the leading icon. Used where the icon *is* the information — the
  /// colourway picker's swatches — rather than a glyph beside a label. Ignored
  /// when the row is disabled or destructive, both of which own the colour.
  final Color? iconColor;

  /// Renders in the error colour — remove from playlist, sign out.
  final bool destructive;

  final bool enabled;
  final Widget? trailing;
}

/// The context menu that appears from a "···" tap.
///
/// Always presented with a header showing what the actions apply to. A bare
/// list of verbs with no subject is a common way these sheets go wrong when
/// they are opened from a long list.
class BottomSheetMenu extends StatelessWidget {
  const BottomSheetMenu({
    required this.actions,
    this.title,
    this.subtitle,
    this.imageUrl,
    this.imageShape = ArtworkShape.square,
    this.leading,
    this.note,
    super.key,
  });

  final List<SheetAction> actions;
  final String? title;
  final String? subtitle;
  final String? imageUrl;
  final ArtworkShape imageShape;

  /// Replaces the header artwork with a widget.
  ///
  /// For subjects whose picture is not a remote image — the signed-in user,
  /// whose avatar is a bundled asset rather than anything [imageUrl] could
  /// address. Takes precedence over [imageUrl] when both are given.
  final Widget? leading;

  /// Explanatory footnote, used to state playback limitations honestly.
  final String? note;

  /// Presents the sheet and returns once it is dismissed.
  static Future<void> show(
    BuildContext context, {
    required List<SheetAction> actions,
    String? title,
    String? subtitle,
    String? imageUrl,
    ArtworkShape imageShape = ArtworkShape.square,
    Widget? leading,
    String? note,
  }) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => BottomSheetMenu(
      actions: actions,
      title: title,
      subtitle: subtitle,
      imageUrl: imageUrl,
      imageShape: imageShape,
      leading: leading,
      note: note,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  AppSpacing.lg,
                ),
                child: Row(
                  children: [
                    leading ??
                        AppArtwork(
                          imageUrl: imageUrl,
                          size: 52,
                          shape: imageShape,
                          seed: title,
                        ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            title!,
                            style: AppTypography.titleMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              subtitle!,
                              style: AppTypography.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, indent: AppSpacing.page, endIndent: AppSpacing.page),
              const SizedBox(height: AppSpacing.sm),
            ],

            for (final action in actions)
              _SheetRow(
                action: action,
                onTap: () {
                  Navigator.of(context).pop();
                  action.onTap();
                },
              ),

            if (note != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.page,
                  AppSpacing.sm,
                  AppSpacing.page,
                  0,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: AurixIcon(
                        AurixGlyph.info,
                        size: 15,
                        color: AppColors.textTertiary,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        note!,
                        style: AppTypography.bodySmall.copyWith(
                          color: AppColors.textTertiary,
                          fontSize: 11.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: AppSpacing.xl),
          ],
        ),
      ),
    );
  }
}

class _SheetRow extends StatelessWidget {
  const _SheetRow({required this.action, required this.onTap});

  final SheetAction action;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = !action.enabled
        ? AppColors.textTertiary
        : action.destructive
            ? AppColors.error
            : AppColors.textPrimary;

    return ListTile(
      onTap: action.enabled ? onTap : null,
      leading: AurixIcon(
        action.icon,
        size: 22,
        color: action.enabled && !action.destructive
            ? (action.iconColor ?? color)
            : color,
      ),
      title: Text(action.label, style: AppTypography.bodyLarge.copyWith(color: color)),
      subtitle: action.subtitle == null
          ? null
          : Text(action.subtitle!, style: AppTypography.bodySmall),
      trailing: action.trailing,
      minLeadingWidth: 24,
      horizontalTitleGap: AppSpacing.lg,
    );
  }
}

/// Confirmation dialog with consistent styling.
class ConfirmDialog extends StatelessWidget {
  const ConfirmDialog({
    required this.title,
    required this.message,
    this.confirmLabel = 'Confirm',
    this.cancelLabel = 'Cancel',
    this.destructive = false,
    super.key,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final String cancelLabel;
  final bool destructive;

  static Future<bool> show(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ConfirmDialog(
        title: title,
        message: message,
        confirmLabel: confirmLabel,
        cancelLabel: cancelLabel,
        destructive: destructive,
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: AppColors.textSecondary),
          child: Text(cancelLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: destructive
              ? FilledButton.styleFrom(
                  backgroundColor: AppColors.error,
                  // Near-black, not white. The error colour is a pale red so
                  // it separates from the brand red on dark surfaces, and
                  // white on it measures only 2.3:1.
                  foregroundColor: AppColors.textOnAccent,
                )
              : null,
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
