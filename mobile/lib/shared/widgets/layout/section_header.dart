import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/utils/responsive.dart';

/// Title above a shelf, with an optional "See all".
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    required this.title,
    this.subtitle,
    this.overline,
    this.actionLabel,
    this.onAction,
    this.padding,
    super.key,
  });

  final String title;
  final String? subtitle;

  /// Small caps line above the title, for editorial framing.
  final String? overline;

  final String? actionLabel;
  final VoidCallback? onAction;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding ??
          EdgeInsets.fromLTRB(
            context.pageGutter,
            0,
            context.pageGutter - AppSpacing.sm,
            AppSpacing.md,
          ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (overline != null) ...[
                  Text(overline!.toUpperCase(), style: AppTypography.overline),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Text(
                  title,
                  style: AppTypography.headlineMedium,
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
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                textStyle: AppTypography.labelMedium,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              ),
              child: Text(actionLabel!),
            ),
        ],
      ),
    );
  }
}

/// A horizontally-scrolling shelf of cards.
///
/// Uses `ListView.separated` with a `cacheExtent` tuned to roughly one card
/// beyond the viewport: enough to make flinging smooth, not so much that eight
/// shelves each build twenty off-screen cards on first frame.
class HorizontalShelf extends StatelessWidget {
  const HorizontalShelf({
    required this.itemCount,
    required this.itemBuilder,
    required this.height,
    this.gap = AppSpacing.carouselGap,
    this.padding,
    super.key,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;
  final double height;
  final double gap;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: padding ??
            EdgeInsets.symmetric(horizontal: context.pageGutter),
        itemCount: itemCount,
        cacheExtent: context.carouselCardWidth * 1.5,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        separatorBuilder: (_, _) => SizedBox(width: gap),
        itemBuilder: itemBuilder,
      ),
    );
  }
}

/// Header + shelf, the pairing used all over Home and the detail screens.
class ShelfSection extends StatelessWidget {
  const ShelfSection({
    required this.title,
    required this.itemCount,
    required this.itemBuilder,
    required this.itemHeight,
    this.subtitle,
    this.overline,
    this.actionLabel,
    this.onAction,
    super.key,
  });

  final String title;
  final String? subtitle;
  final String? overline;
  final String? actionLabel;
  final VoidCallback? onAction;
  final int itemCount;
  final double itemHeight;
  final Widget Function(BuildContext, int) itemBuilder;

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(
          title: title,
          subtitle: subtitle,
          overline: overline,
          actionLabel: actionLabel,
          onAction: onAction,
        ),
        HorizontalShelf(
          itemCount: itemCount,
          itemBuilder: itemBuilder,
          height: itemHeight,
        ),
      ],
    );
  }
}

/// Divider used between settings groups and library sections.
class SectionDivider extends StatelessWidget {
  const SectionDivider({this.indent = AppSpacing.page, super.key});

  final double indent;

  @override
  Widget build(BuildContext context) => Divider(
    height: AppSpacing.xxl,
    indent: indent,
    endIndent: indent,
    color: AppColors.divider,
  );
}
