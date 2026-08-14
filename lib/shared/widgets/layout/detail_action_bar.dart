import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../controls/play_button.dart';

/// The action row under a detail header: save, share, more … then shuffle and
/// the big play button.
///
/// Right-aligning the two playback controls and left-aligning the secondary
/// icons is what every music app converges on, and it keeps the primary action
/// under the thumb on a phone.
class DetailActionBar extends StatelessWidget {
  const DetailActionBar({
    required this.isPlaying,
    required this.onPlay,
    required this.onShuffle,
    this.isSaved,
    this.onSaveToggle,
    this.saveTooltip,
    this.onShare,
    this.onMore,
    this.isShuffled = false,
    this.playEnabled = true,
    this.isLoading = false,
    this.leadingExtra,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback onPlay;
  final VoidCallback onShuffle;

  /// Null hides the save control (e.g. the user's own playlist).
  final bool? isSaved;
  final VoidCallback? onSaveToggle;
  final String? saveTooltip;

  final VoidCallback? onShare;
  final VoidCallback? onMore;
  final bool isShuffled;
  final bool playEnabled;
  final bool isLoading;

  /// Extra control inserted before the save button — the Follow pill on an
  /// artist screen.
  final Widget? leadingExtra;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          if (leadingExtra != null) ...[
            leadingExtra!,
            const SizedBox(width: AppSpacing.md),
          ],

          if (isSaved != null)
            Tooltip(
              message: saveTooltip ??
                  (isSaved! ? 'Remove from your library' : 'Save to your library'),
              child: IconButton(
                onPressed: onSaveToggle,
                iconSize: 27,
                icon: AurixIcon(
                  isSaved!
                      ? AurixGlyph.checkCircle
                      : AurixGlyph.add,
                  color: isSaved! ? context.palette.accent : AppColors.textSecondary,
                ),
              ),
            ),

          if (onShare != null)
            IconButton(
              onPressed: onShare,
              iconSize: 24,
              icon: const AurixIcon(AurixGlyph.share, color: AppColors.textSecondary),
              tooltip: 'Share',
            ),

          if (onMore != null)
            IconButton(
              onPressed: onMore,
              iconSize: 26,
              icon: const AurixIcon(AurixGlyph.more, color: AppColors.textSecondary),
              tooltip: 'More options',
            ),

          const Spacer(),

          TransportButton(
            icon: AurixGlyph.shuffle,
            tooltip: isShuffled ? 'Shuffle on' : 'Shuffle',
            active: isShuffled,
            enabled: playEnabled,
            onPressed: onShuffle,
            size: 26,
          ),
          const SizedBox(width: AppSpacing.sm),
          PlayButton(
            isPlaying: isPlaying,
            isLoading: isLoading,
            enabled: playEnabled,
            onPressed: onPlay,
          ),
        ],
      ),
    );
  }
}

/// Sticky bar shown once the header scrolls away, so play is always reachable.
class CollapsedPlayBar extends StatelessWidget {
  const CollapsedPlayBar({
    required this.visible,
    required this.title,
    required this.isPlaying,
    required this.onPlay,
    super.key,
  });

  final bool visible;
  final String title;
  final bool isPlaying;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    return AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, -1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 180),
        child: ColoredBox(
          color: AppColors.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.page,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                PlayButton(isPlaying: isPlaying, onPressed: onPlay, size: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
