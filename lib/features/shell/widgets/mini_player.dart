import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../playback/playback_mode.dart';
import '../../../playback/player_controller.dart';
import '../../../shared/widgets/controls/music_progress_bar.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';
import '../../../shared/widgets/media/app_artwork.dart';

/// The persistent player bar.
///
/// Mounted by [GlobalMiniPlayer] *above* the router's `Navigator`, not inside
/// the shell. It used to sit in the shell's `bottomNavigationBar`, which looked
/// global but was not: every detail route — album, artist, playlist, settings
/// and Liked Songs — is pushed onto the **root** navigator and therefore covers
/// the shell entirely, taking the mini player with it. Opening Liked Songs
/// while music played made the bar vanish.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  /// Shared Hero tag so artwork flies between the mini and full player.
  static const String artworkHeroTag = 'now-playing-artwork';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Timeline-agnostic, because everything below the hairline is expensive and
    // none of it moves with the position: this bar is mounted on *every* screen
    // and blurs whatever is behind it at 24 sigma, so watching the full state
    // meant a `saveLayer` and a full-width blur twice a second for as long as
    // anything played. The hairline is the one part that does move, and it
    // subscribes to the position on its own, below.
    final state = ref.watch(playbackStateProvider);
    final track = state.track;

    // AnimatedSize + SizeTransition would fight the bottom nav's layout; a
    // simple presence check keeps the bar out of the tree entirely when idle.
    if (track == null) return const SizedBox.shrink();

    final controller = ref.read(playerControllerProvider.notifier);
    // `peek` only — a synchronous cache read. The full player does the async
    // extraction; the mini player borrows the result if it happens to be
    // there, and falls back to the neutral surface if not.
    final palette = ref.watch(albumPaletteServiceProvider).peek(track.thumbnailUrl);
    // Named `brand` to keep it distinct from the artwork-derived `palette`
    // above: one is sampled from the cover, the other is the colourway.
    final brand = context.palette;

    return Semantics(
      container: true,
      label: 'Now playing: ${track.name} by ${track.artistNames}',
      child: GestureDetector(
        // Navigates through the router object rather than `context`: mounted
        // above the `Navigator`, this widget has no `GoRouter` ancestor to
        // find.
        onTap: () => ref.read(routerProvider).pushDistinct(RouteNames.player),
        // Swipe up to expand — the gesture users try first.
        onVerticalDragEnd: (details) {
          if ((details.primaryVelocity ?? 0) < -220) {
            ref.read(routerProvider).pushDistinct(RouteNames.player);
          }
        },
        // Frosted, not filled. This is one of the four surfaces the brief
        // allows glass on, and it is the one that earns it most: the bar floats
        // over whatever list is scrolling beneath it, so there is always
        // something worth blurring. An opaque card here would cut a hard slab
        // across the content and lose the sense that the app continues behind
        // it.
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            border: Border.all(color: brand.glassBorder),
            boxShadow: [
              // Black, and only black. The bar used to carry a brand bloom
              // underneath so it read as "lit"; in white that bloom is the
              // brightest thing on the screen and steals rank from the play
              // button. Depth here is a shadow, which is what depth is.
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  // The frosted fill, plus a whisper of the artwork's own
                  // brightness bleeding in from the left — already greyscale by
                  // the time it reaches here, so it lifts the tone under the
                  // cover without introducing a colour.
                  gradient: LinearGradient(
                    colors: [
                      Color.lerp(
                        palette?.base ?? brand.surfaceElevated,
                        brand.surfaceElevated,
                        0.55,
                      )!.withValues(alpha: 0.72),
                      brand.surfaceElevated.withValues(alpha: 0.66),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: AppSizes.miniPlayerHeight,
                      child: Row(
                        children: [
                    const SizedBox(width: AppSpacing.sm),
                    Hero(
                      tag: artworkHeroTag,
                      child: AppArtwork(
                        imageUrl: track.thumbnailUrl,
                        size: 44,
                        seed: track.id,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track.name,
                            style: AppTypography.titleSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 1),
                          Row(
                            children: [
                              if (state.mode == PlaybackMode.connect &&
                                  state.activeDevice != null) ...[
                                AurixIcon(
                                  AurixGlyph.devices,
                                  size: 12,
                                  color: brand.accent,
                                ),
                                const SizedBox(width: 3),
                                Flexible(
                                  child: Text(
                                    state.activeDevice!.name,
                                    style: AppTypography.labelMedium.copyWith(
                                      fontSize: 10.5,
                                      color: brand.accent,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ] else ...[
                                if (state.isPreviewOnly) ...[
                                  const _PreviewChip(),
                                  const SizedBox(width: AppSpacing.xs + 2),
                                ],
                                Flexible(
                                  child: Text(
                                    track.artistNames,
                                    style: AppTypography.bodySmall.copyWith(
                                      fontSize: 11.5,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    _MiniControl(
                      icon: state.isPlaying
                          ? AurixGlyph.pause
                          : AurixGlyph.play,
                      tooltip: state.isPlaying ? 'Pause' : 'Play',
                      enabled: state.mode.isPlayable || state.mode == PlaybackMode.idle,
                      busy: state.isBuffering,
                      onTap: controller.togglePlayPause,
                    ),
                    _MiniControl(
                      icon: AurixGlyph.skipNext,
                      tooltip: 'Next',
                      enabled: state.queue.hasNext,
                      onTap: () => controller.next(),
                    ),
                          const SizedBox(width: AppSpacing.xs),
                        ],
                      ),
                    ),
                    // The only part of the bar that tracks the position, and
                    // the only part cheap enough to: two pixels of solid
                    // colour, rebuilt inside its own `Consumer` so the blur
                    // above it is untouched.
                    Consumer(
                      builder: (context, ref, _) => HairlineProgress(
                        progress: ref.watch(playbackProgressProvider),
                        color: state.mode == PlaybackMode.unavailable
                            ? brand.textTertiary
                            : brand.accent,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniControl extends StatelessWidget {
  const _MiniControl({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
  });

  final AurixGlyph icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox.square(
        dimension: 44,
        child: Center(
          child: SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // No `Tooltip`. The bar is mounted above the router's `Navigator`, where
    // there is no `Overlay` for a tooltip to grow into — and a tooltip on a
    // touch-only control needs a long-press to find anyway. The label goes to
    // the glyph instead, which is what a screen reader reads.
    return IconButton(
      onPressed: enabled ? onTap : null,
      iconSize: 26,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      icon: AnimatedSwitcher(
        duration: AppConstants.fast,
        child: AurixIcon(
          icon,
          key: ValueKey(icon),
          size: 26,
          color: enabled
              ? context.palette.textPrimary
              : context.palette.textTertiary,
          semanticLabel: tooltip,
        ),
      ),
    );
  }
}

/// Marks that only Spotify's 30-second excerpt is playing.
class _PreviewChip extends StatelessWidget {
  const _PreviewChip();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: palette.surfaceHighest,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: palette.hairline),
      ),
      child: Text(
        '0:30',
        style: AppTypography.labelSmall.copyWith(
          fontSize: 8.5,
          letterSpacing: 0.2,
          color: palette.textSecondary,
        ),
      ),
    );
  }
}

