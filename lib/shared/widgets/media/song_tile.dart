import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/utils/formatters.dart';
import '../../../data/models/track.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import 'app_artwork.dart';
import 'content_cards.dart';

/// How much of a track row to show, which differs by screen.
enum SongTileVariant {
  /// Artwork + title + artist. Search results, liked songs, queue.
  standard,

  /// Track number instead of artwork. Album screen, where every row shares
  /// the same cover and repeating it 14 times is pure noise.
  numbered,

  /// Compact, no artwork. Artist "popular tracks".
  compact,
}

/// A single track row.
///
/// One widget covers every list in the app so a song looks and behaves the
/// same everywhere. The two states that matter most are handled here rather
/// than by callers:
///
///  * **Now playing** — the title turns accent-coloured and an equaliser
///    marker replaces the track number, so the current song is findable in a
///    long list without scrolling to the mini player.
///  * **Unplayable** — a local file, or a track Spotify marks unavailable in
///    this market, is dimmed and non-interactive. Letting the user tap it and
///    silently do nothing is worse than showing it cannot be played.
class SongTile extends StatelessWidget {
  const SongTile({
    required this.track,
    required this.onTap,
    this.variant = SongTileVariant.standard,
    this.index,
    this.isPlaying = false,
    this.isCurrent = false,
    this.isSaved,
    this.onSaveToggle,
    this.onMore,
    this.trailing,
    this.showAlbumName = false,
    this.dense = false,
    super.key,
  });

  final Track track;
  final VoidCallback onTap;
  final SongTileVariant variant;

  /// 1-based position, for [SongTileVariant.numbered].
  final int? index;

  final bool isPlaying;
  final bool isCurrent;

  /// Null hides the like button entirely (e.g. inside the queue).
  final bool? isSaved;
  final VoidCallback? onSaveToggle;
  final VoidCallback? onMore;

  /// Overrides the default trailing area.
  final Widget? trailing;

  final bool showAlbumName;
  final bool dense;

  bool get _isPlayable => !track.isLocal && (track.isPlayable ?? true);

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    final titleColor = !_isPlayable
        ? AppColors.textTertiary
        : isCurrent
            ? accent
            : AppColors.textPrimary;

    final subtitle = showAlbumName && track.album != null
        ? '${track.artistNames} · ${track.album!.name}'
        : track.artistNames;

    return Semantics(
      button: true,
      selected: isCurrent,
      label: 'Play ${track.name} by ${track.artistNames}',
      child: InkWell(
        onTap: _isPlayable ? onTap : null,
        onLongPress: onMore,
        splashColor: AppColors.overlayHover,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.page,
            vertical: dense ? AppSpacing.xs + 2 : AppSpacing.sm,
          ),
          child: Row(
            children: [
              _leading(titleColor),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      track.name,
                      style: AppTypography.titleMedium.copyWith(color: titleColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        if (track.isExplicit) ...[
                          const ExplicitBadge(),
                          const SizedBox(width: AppSpacing.xs + 1),
                        ],
                        Expanded(
                          child: Text(
                            subtitle,
                            style: AppTypography.bodySmall.copyWith(
                              color: _isPlayable
                                  ? AppColors.textSecondary
                                  : AppColors.textTertiary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _trailing(accent),
            ],
          ),
        ),
      ),
    );
  }

  Widget _leading(Color titleColor) {
    switch (variant) {
      case SongTileVariant.numbered:
        return SizedBox(
          width: 26,
          child: Center(
            child: isCurrent
                ? PlayingIndicator(animate: isPlaying)
                : Text(
                    '${index ?? track.trackNumber}',
                    style: AppTypography.bodyMedium.copyWith(
                      color: _isPlayable
                          ? AppColors.textSecondary
                          : AppColors.textTertiary,
                    ),
                  ),
          ),
        );

      case SongTileVariant.compact:
        return SizedBox(
          width: 26,
          child: Center(
            child: isCurrent
                ? PlayingIndicator(animate: isPlaying)
                : Text(
                    '${index ?? 0}',
                    style: AppTypography.bodyMedium.copyWith(
                      color: AppColors.textSecondary,
                    ),
                  ),
          ),
        );

      case SongTileVariant.standard:
        final size = dense ? AppSizes.tileArtwork : AppSizes.tileArtworkLarge;
        return Stack(
          alignment: Alignment.center,
          children: [
            Opacity(
              opacity: _isPlayable ? 1 : 0.45,
              child: AppArtwork(
                imageUrl: track.thumbnailUrl,
                size: size,
                seed: track.id,
              ),
            ),
            if (isCurrent)
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.55),
                  borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
                ),
                child: Center(child: PlayingIndicator(animate: isPlaying)),
              ),
          ],
        );
    }
  }

  /// [accent] is threaded in rather than read from context: this runs outside
  /// `build`, so there is no context to resolve the colourway from here.
  Widget _trailing(Color accent) {
    if (trailing != null) return trailing!;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_isPlayable)
          Tooltip(
            message: track.isLocal
                ? 'Local file — not available through Spotify'
                : 'Not available in your region',
            child: const AurixIcon(
              AurixGlyph.block,
              size: 18,
              color: AppColors.textTertiary,
            ),
          )
        else if (variant != SongTileVariant.standard)
          Text(
            Formatters.durationMs(track.durationMs),
            style: AppTypography.timecode,
          ),
        if (isSaved != null) ...[
          const SizedBox(width: AppSpacing.xs),
          IconButton(
            onPressed: onSaveToggle,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: AurixIcon(
              isSaved! ? AurixGlyph.heartFilled : AurixGlyph.heart,
              color: isSaved! ? accent : AppColors.textSecondary,
            ),
            tooltip: isSaved! ? 'Remove from Liked Songs' : 'Save to Liked Songs',
          ),
        ],
        if (onMore != null)
          IconButton(
            onPressed: onMore,
            iconSize: 20,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
            icon: const AurixIcon(AurixGlyph.more, color: AppColors.textSecondary),
            tooltip: 'More options',
          ),
      ],
    );
  }
}

/// The three-bar equaliser that marks the current track.
///
/// Animates only while audio is actually playing — a bouncing equaliser over a
/// paused track is a small lie, and it also keeps a repaint running forever.
class PlayingIndicator extends StatefulWidget {
  const PlayingIndicator({this.animate = true, this.color, this.size = 16, super.key});

  final bool animate;
  final Color? color;
  final double size;

  @override
  State<PlayingIndicator> createState() => _PlayingIndicatorState();
}

class _PlayingIndicatorState extends State<PlayingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) _controller.repeat();
  }

  @override
  void didUpdateWidget(PlayingIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate == oldWidget.animate) return;
    if (widget.animate) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.palette.accent;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: List.generate(3, (i) {
              // Phase-shift each bar so they never move in unison.
              final phase = (_controller.value + (i * 0.33)) % 1.0;
              final wave = 0.35 + (0.65 * (1 - (phase - 0.5).abs() * 2));
              final height = widget.animate
                  ? widget.size * wave
                  : widget.size * (i == 1 ? 0.7 : 0.4);
              return Container(
                width: widget.size * 0.22,
                height: height,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(widget.size * 0.11),
                ),
              );
            }),
          );
        },
      ),
    );
  }
}
