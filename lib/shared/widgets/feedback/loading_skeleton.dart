import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// A single shimmering block.
///
/// Skeletons mirror the *shape* of the content they stand in for, not a
/// generic spinner — the layout does not reflow when data arrives, which is
/// what makes loading feel fast rather than merely animated.
class SkeletonBox extends StatelessWidget {
  const SkeletonBox({
    required this.width,
    required this.height,
    this.borderRadius,
    this.animate = true,
    super.key,
  });

  const SkeletonBox.circle({
    required double size,
    bool animate = true,
    Key? key,
  }) : this(
         width: size,
         height: size,
         borderRadius: const BorderRadius.all(Radius.circular(AppRadius.pill)),
         animate: animate,
         key: key,
       );

  /// A text-line placeholder, sized as a fraction of the available width.
  const SkeletonBox.text({
    required double width,
    double height = 12,
    bool animate = true,
    Key? key,
  }) : this(
         width: width,
         height: height,
         borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
         animate: animate,
         key: key,
       );

  final double width;
  final double height;
  final BorderRadius? borderRadius;

  /// Set false to honour "reduce motion" — the block still holds the layout,
  /// it simply does not pulse.
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final box = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.shimmerBase,
        borderRadius: borderRadius ?? AppRadius.artwork,
      ),
    );

    if (!animate) return box;

    return box
        .animate(onPlay: (controller) => controller.repeat())
        .shimmer(
          duration: 1400.ms,
          color: AppColors.shimmerHighlight,
          angle: 0.4,
        );
  }
}

/// Skeleton for one carousel card.
class SkeletonCard extends StatelessWidget {
  const SkeletonCard({
    required this.width,
    this.circular = false,
    this.animate = true,
    super.key,
  });

  final double width;
  final bool circular;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          circular
              ? SkeletonBox.circle(size: width, animate: animate)
              : SkeletonBox(
                  width: width,
                  height: width,
                  borderRadius: AppRadius.artwork,
                  animate: animate,
                ),
          const SizedBox(height: AppSpacing.sm),
          SkeletonBox.text(width: width * 0.78, animate: animate),
          const SizedBox(height: AppSpacing.xs + 2),
          SkeletonBox.text(width: width * 0.52, height: 10, animate: animate),
        ],
      ),
    );
  }
}

/// Skeleton for a horizontal shelf, header included.
class SkeletonShelf extends StatelessWidget {
  const SkeletonShelf({
    required this.cardWidth,
    this.itemCount = 4,
    this.circular = false,
    this.animate = true,
    super.key,
  });

  final double cardWidth;
  final int itemCount;
  final bool circular;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
          child: SkeletonBox.text(width: 148, height: 20, animate: animate),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: cardWidth + 58,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
            itemCount: itemCount,
            separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.carouselGap),
            itemBuilder: (_, _) => SkeletonCard(
              width: cardWidth,
              circular: circular,
              animate: animate,
            ),
          ),
        ),
      ],
    );
  }
}

/// Skeleton for a track row.
class SkeletonTile extends StatelessWidget {
  const SkeletonTile({this.animate = true, this.showLeading = true, super.key});

  final bool animate;
  final bool showLeading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          if (showLeading) ...[
            SkeletonBox(
              width: AppSizes.tileArtwork,
              height: AppSizes.tileArtwork,
              borderRadius: AppRadius.artwork,
              animate: animate,
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                SkeletonBox.text(width: 190, animate: animate),
                const SizedBox(height: AppSpacing.sm),
                SkeletonBox.text(width: 120, height: 10, animate: animate),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Skeleton for a whole list of track rows.
class SkeletonTrackList extends StatelessWidget {
  const SkeletonTrackList({this.itemCount = 8, this.animate = true, super.key});

  final int itemCount;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        itemCount,
        (_) => SkeletonTile(animate: animate),
      ),
    );
  }
}

/// Skeleton for an immersive detail header (album, artist, playlist).
class SkeletonDetailHeader extends StatelessWidget {
  const SkeletonDetailHeader({this.artworkSize = 200, this.animate = true, super.key});

  final double artworkSize;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.xxl,
      ),
      child: Column(
        children: [
          SkeletonBox(
            width: artworkSize,
            height: artworkSize,
            borderRadius: AppRadius.card,
            animate: animate,
          ),
          const SizedBox(height: AppSpacing.xl),
          SkeletonBox.text(width: 220, height: 26, animate: animate),
          const SizedBox(height: AppSpacing.md),
          SkeletonBox.text(width: 150, height: 12, animate: animate),
          const SizedBox(height: AppSpacing.xl),
          Row(
            children: [
              SkeletonBox.circle(size: 40, animate: animate),
              const SizedBox(width: AppSpacing.lg),
              SkeletonBox.circle(size: 40, animate: animate),
              const Spacer(),
              SkeletonBox.circle(size: 56, animate: animate),
            ],
          ),
        ],
      ),
    );
  }
}
