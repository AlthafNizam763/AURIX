import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/album_palette.dart';
import '../effects/grain.dart';

/// Full-bleed gradient derived from artwork, sitting behind a detail screen.
///
/// Painted as a separate layer under the scroll view rather than inside the
/// header, so the colour persists as the user scrolls past the header instead
/// of cutting off at its edge — that abrupt seam is the giveaway that a
/// gradient was bolted onto an app bar.
class PaletteBackdrop extends StatelessWidget {
  const PaletteBackdrop({
    required this.palette,
    required this.child,
    this.height = 420,
    super.key,
  });

  final AlbumPalette palette;
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: height,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: palette.headerGradient(context.palette),
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0, 0.55, 1],
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}

/// Collapsing header for album, artist and playlist screens.
///
/// Two behaviours make this feel native rather than templated:
///
///  * The artwork scales and fades on its own curve as the header collapses,
///    reaching zero opacity slightly before the bar locks — so the title
///    never overlaps a ghost of the cover.
///  * The pinned bar's background only appears once the content is actually
///    behind it, computed from the real collapse fraction rather than a
///    scroll-offset guess.
class ImmersiveHeader extends StatelessWidget {
  const ImmersiveHeader({
    required this.title,
    required this.artwork,
    required this.palette,
    this.subtitle,
    this.metadata,
    this.overline,
    this.expandedHeight = AppSizes.headerExpanded,
    this.actions,
    this.centerArtwork = true,
    this.blurArtwork = false,
    super.key,
  });

  final String title;
  final Widget artwork;
  final AlbumPalette palette;
  final String? subtitle;

  /// One-line credit strip under the title ("2019 · 12 songs · 48 min").
  final Widget? metadata;

  final String? overline;
  final double expandedHeight;
  final List<Widget>? actions;
  final bool centerArtwork;

  /// Blurs the artwork behind the content — used on artist headers where the
  /// image is full-bleed rather than a floating square.
  final bool blurArtwork;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.paddingOf(context).top;

    return SliverAppBar(
      pinned: true,
      stretch: true,
      expandedHeight: expandedHeight,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      actions: actions,
      flexibleSpace: LayoutBuilder(
        builder: (context, constraints) {
          final maxExtent = expandedHeight + topPadding;
          final minExtent = AppSizes.headerCollapsed + topPadding;
          final range = (maxExtent - minExtent).clamp(1.0, double.infinity);
          // 0 = fully expanded, 1 = fully collapsed.
          final t = ((maxExtent - constraints.maxHeight) / range).clamp(0.0, 1.0);

          return FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(
              start: 56,
              end: 56,
              bottom: 16,
            ),
            centerTitle: true,
            title: Opacity(
              // Fade the pinned title in only over the last third of the
              // collapse, so it does not compete with the large title.
              opacity: ((t - 0.62) / 0.38).clamp(0.0, 1.0),
              child: Text(
                title,
                style: AppTypography.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            background: _Background(
              artwork: artwork,
              palette: palette,
              title: title,
              subtitle: subtitle,
              metadata: metadata,
              overline: overline,
              collapse: t,
              centerArtwork: centerArtwork,
              blurArtwork: blurArtwork,
            ),
          );
        },
      ),
    );
  }
}

class _Background extends StatelessWidget {
  const _Background({
    required this.artwork,
    required this.palette,
    required this.title,
    required this.collapse,
    required this.centerArtwork,
    required this.blurArtwork,
    this.subtitle,
    this.metadata,
    this.overline,
  });

  final Widget artwork;
  final AlbumPalette palette;
  final String title;
  final String? subtitle;
  final Widget? metadata;
  final String? overline;
  final double collapse;
  final bool centerArtwork;
  final bool blurArtwork;

  @override
  Widget build(BuildContext context) {
    final artOpacity = (1 - (collapse * 1.5)).clamp(0.0, 1.0);
    final artScale = 1 - (collapse * 0.18);

    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: palette.headerGradient(context.palette),
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              stops: const [0, 0.6, 1],
            ),
          ),
        ),

        if (blurArtwork)
          Positioned.fill(
            child: Opacity(
              opacity: artOpacity * 0.65,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
                child: artwork,
              ),
            ),
          ),

        // Grain over the artwork-derived gradient.
        //
        // This is doing more than decorating. The gradient behind it is a long
        // fade across a very narrow band of near-blacks, which is precisely the
        // case 8-bit colour cannot represent smoothly — without the dither this
        // header shows visible horizontal steps on an OLED panel.
        //
        // It fades out as the header collapses: at the pinned height it would
        // sit directly behind the title, and texture behind text is the fastest
        // way to make a detail screen look cheap.
        //
        // Sits *above* the blurred artwork so it reads as part of the panel
        // rather than as an artefact of the blur, and *below* the scrim so the
        // scrim still guarantees text contrast.
        if (artOpacity > 0.01)
          Positioned.fill(
            child: IgnorePointer(
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: GrainPainter(
                    color: context.palette.grain,
                    fade: GrainFade.top,
                    opacity: artOpacity,
                  ),
                ),
              ),
            ),
          ),

        // A scrim under the text guarantees contrast no matter how bright the
        // sampled colour turned out.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.28),
                  Colors.black.withValues(alpha: 0.68),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.35, 0.7, 1],
              ),
            ),
          ),
        ),

        SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.page,
              AppSizes.headerCollapsed,
              AppSpacing.page,
              AppSpacing.lg,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: centerArtwork
                  ? CrossAxisAlignment.center
                  : CrossAxisAlignment.start,
              children: [
                if (!blurArtwork)
                  Expanded(
                    child: Center(
                      child: Opacity(
                        opacity: artOpacity,
                        child: Transform.scale(scale: artScale, child: artwork),
                      ),
                    ),
                  )
                else
                  const Spacer(),
                const SizedBox(height: AppSpacing.lg),
                if (overline != null) ...[
                  Text(overline!.toUpperCase(), style: AppTypography.overline),
                  const SizedBox(height: AppSpacing.xs),
                ],
                Text(
                  title,
                  style: _titleStyle(title),
                  textAlign: centerArtwork ? TextAlign.center : TextAlign.start,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: AppSpacing.xs + 2),
                  Text(
                    subtitle!,
                    style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.textPrimary.withValues(alpha: 0.82),
                    ),
                    textAlign: centerArtwork ? TextAlign.center : TextAlign.start,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                if (metadata != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  metadata!,
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Long titles step down a size rather than wrapping to three cramped lines.
  TextStyle _titleStyle(String value) {
    if (value.length > 34) return AppTypography.displaySmall;
    if (value.length > 18) return AppTypography.displayMedium;
    return AppTypography.displayLarge;
  }
}

/// The metadata strip used under a detail header.
class MetadataStrip extends StatelessWidget {
  const MetadataStrip({required this.parts, this.leading, this.center = true, super.key});

  final List<String> parts;
  final Widget? leading;
  final bool center;

  @override
  Widget build(BuildContext context) {
    final visible = parts.where((p) => p.isNotEmpty).toList();
    if (visible.isEmpty && leading == null) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: center ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        if (leading != null) ...[leading!, const SizedBox(width: AppSpacing.sm)],
        Flexible(
          child: Text(
            visible.join(' · '),
            style: AppTypography.bodySmall.copyWith(
              color: AppColors.textPrimary.withValues(alpha: 0.7),
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
