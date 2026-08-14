import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/formatters.dart';
import '../../data/models/track.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';

/// The playback queue: what is playing, and what is next.
///
/// "Next up" is reorderable and swipe-to-remove. Both operate on the *playback
/// order*, not the underlying track list — see `PlaybackQueue.reorderUpNext`,
/// which translates the indices. Getting that translation wrong is how queue
/// UIs end up playing the song above the one you dragged.
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Timeline-agnostic — this screen draws no scrubber, and its Up Next list
    // is a full reorderable rebuild.
    final state = ref.watch(playbackStateProvider);
    final controller = ref.read(playerControllerProvider.notifier);
    final current = state.track;
    final upNext = state.queue.upNext;

    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const AurixIcon(AurixGlyph.chevronDown, size: 30),
          tooltip: 'Close',
        ),
        title: Column(
          children: [
            const Text('Queue', style: AppTypography.titleMedium),
            Text(
              state.context.title,
              style: AppTypography.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (upNext.isNotEmpty)
            IconButton(
              onPressed: () => _confirmClear(context, controller),
              icon: const AurixIcon(AurixGlyph.trash),
              tooltip: 'Clear up next',
            ),
        ],
      ),
      body: current == null
          ? const EmptyView(
              icon: AurixGlyph.playlist,
              title: 'The queue is empty',
              message: 'Play something and the rest of the queue shows up here.',
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _NowPlayingCard(track: current, isPlaying: state.isPlaying),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.xl,
                      AppSpacing.page,
                      AppSpacing.sm,
                    ),
                    child: Row(
                      children: [
                        const Expanded(
                          child: Text('Next up', style: AppTypography.headlineSmall),
                        ),
                        if (upNext.isNotEmpty)
                          Text(
                            '${upNext.length} ${upNext.length == 1 ? 'song' : 'songs'}',
                            style: AppTypography.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),

                if (upNext.isEmpty)
                  const SliverToBoxAdapter(
                    child: EmptyView(
                      icon: AurixGlyph.add,
                      title: 'Nothing up next',
                      message: 'Add songs from anywhere in the app.',
                      compact: true,
                    ),
                  )
                else
                  SliverReorderableList(
                    itemCount: upNext.length,
                    onReorder: controller.reorderQueue,
                    proxyDecorator: _dragProxy,
                    itemBuilder: (context, index) {
                      final track = upNext[index];
                      return _QueueRow(
                        // Index in the key as well as the ID: a queue can
                        // legitimately hold the same track twice, and an
                        // ID-only key would make the reorder animation swap
                        // the wrong rows.
                        key: ValueKey('${track.id}-$index'),
                        track: track,
                        index: index,
                        onTap: () => controller.jumpToQueueIndex(index),
                        onRemove: () {
                          controller.removeFromQueue(index);
                          AppSnackbar.show(context, 'Removed from queue');
                        },
                        onMore: () => _showRowMenu(context, ref, track, index),
                      );
                    },
                  ),

                SliverToBoxAdapter(
                  child: SizedBox(
                    height: MediaQuery.paddingOf(context).bottom + AppSpacing.huge,
                  ),
                ),
              ],
            ),
    );
  }

  /// Lifts the dragged row with a shadow so it reads as picked up.
  Widget _dragProxy(Widget child, int index, Animation<double> animation) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, _) {
        final t = Curves.easeInOut.transform(animation.value);
        return Material(
          color: Color.lerp(
            Colors.transparent,
            context.palette.surfaceElevated,
            t,
          ),
          elevation: t * 8,
          borderRadius: AppRadius.card,
          shadowColor: Colors.black,
          child: child,
        );
      },
    );
  }

  Future<void> _confirmClear(
    BuildContext context,
    PlayerController controller,
  ) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Clear up next?',
      message: 'Everything after the current song will be removed from the queue.',
      confirmLabel: 'Clear',
      destructive: true,
    );
    if (confirmed) controller.clearUpNext();
  }

  void _showRowMenu(
    BuildContext context,
    WidgetRef ref,
    Track track,
    int index,
  ) {
    final controller = ref.read(playerControllerProvider.notifier);
    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl,
      actions: [
        SheetAction(
          icon: AurixGlyph.play,
          label: 'Play now',
          onTap: () => controller.jumpToQueueIndex(index),
        ),
        SheetAction(
          icon: AurixGlyph.trending,
          label: 'Move to top of queue',
          enabled: index > 0,
          onTap: () => controller.reorderQueue(index, 0),
        ),
        SheetAction(
          icon: AurixGlyph.close,
          label: 'Remove from queue',
          destructive: true,
          onTap: () => controller.removeFromQueue(index),
        ),
      ],
    );
  }
}

class _NowPlayingCard extends StatelessWidget {
  const _NowPlayingCard({required this.track, required this.isPlaying});

  final Track track;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.glow(0.35)),
      ),
      child: Row(
        children: [
          AppArtwork(
            imageUrl: track.thumbnailUrl,
            size: AppSizes.tileArtworkLarge,
            seed: track.id,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'NOW PLAYING',
                  style: AppTypography.labelSmall.copyWith(
                    color: context.palette.accent,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  track.name,
                  style: AppTypography.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  track.artistNames,
                  style: AppTypography.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          PlayingIndicator(animate: isPlaying, size: 18),
        ],
      ),
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    required this.track,
    required this.index,
    required this.onTap,
    required this.onRemove,
    required this.onMore,
    super.key,
  });

  final Track track;
  final int index;
  final VoidCallback onTap;
  final VoidCallback onRemove;
  final VoidCallback onMore;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: ValueKey('dismiss-${track.id}-$index'),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onRemove(),
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: AppSpacing.xxl),
        color: context.palette.attention.withValues(alpha: 0.85),
        child: const AurixIcon(AurixGlyph.trash, color: Colors.white),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.page,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                AppArtwork(
                  imageUrl: track.thumbnailUrl,
                  size: AppSizes.tileArtwork,
                  seed: track.id,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        track.name,
                        style: AppTypography.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${track.artistNames} · ${Formatters.durationMs(track.durationMs)}',
                        style: AppTypography.bodySmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: onMore,
                  icon: const AurixIcon(AurixGlyph.more, size: 20),
                  color: context.palette.textSecondary,
                  visualDensity: VisualDensity.compact,
                  tooltip: 'More options',
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.sm,
                      vertical: AppSpacing.md,
                    ),
                    child: AurixIcon(
                      AurixGlyph.dragHandle,
                      size: 22,
                      color: context.palette.textTertiary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
