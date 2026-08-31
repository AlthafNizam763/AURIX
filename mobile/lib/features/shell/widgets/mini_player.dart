import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/navigation.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../core/theme/player_themes.dart';
import '../../../core/theme/theme_config.dart';
import '../../../core/theme/theme_controller.dart';
import '../../../core/utils/album_palette.dart';
import '../../../data/models/track.dart';
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
///
/// ## Three designs, one implementation
///
/// The bar's *chrome* comes from [MiniPlayerStyle], selected by the operator in
/// Settings → Appearance. Everything below — the Connect-device row, the
/// buffering state, the preview chip, the semantics label — is shared by all
/// three, which is the point: a variant chooses a shape, not a fork of the
/// widget. See the note at the top of `player_themes.dart`.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  /// Shared Hero tag so artwork flies between the mini and full player.
  static const String artworkHeroTag = 'now-playing-artwork';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Timeline-agnostic, because everything below the hairline is expensive and
    // none of it moves with the position: this bar is mounted on *every* screen
    // and (in theme 1) blurs whatever is behind it at 24 sigma, so watching the
    // full state meant a `saveLayer` and a full-width blur twice a second for
    // as long as anything played. The hairline is the one part that does move,
    // and it subscribes to the position on its own, below.
    final state = ref.watch(playbackStateProvider);
    final track = state.track;

    // AnimatedSize + SizeTransition would fight the bottom nav's layout; a
    // simple presence check keeps the bar out of the tree entirely when idle.
    if (track == null) return const SizedBox.shrink();

    // Only this surface's variant, so changing the *large* player's theme does
    // not rebuild the bar that is mounted on every screen.
    final style = MiniPlayerStyle.of(
      ref.watch(playerVariantProvider(PlayerSurface.mini)),
    );

    // `peek` only — a synchronous cache read. The full player does the async
    // extraction; the mini player borrows the result if it happens to be
    // there, and falls back to the neutral surface if not.
    final artworkTint = style.tintsFromArtwork
        ? ref.watch(albumPaletteServiceProvider).peek(track.thumbnailUrl)
        : null;

    // Named `brand` to keep it distinct from the artwork-derived tint above:
    // one is sampled from the cover, the other is the configured palette.
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
        child: Container(
          margin: EdgeInsets.fromLTRB(
            style.horizontalMargin,
            0,
            style.horizontalMargin,
            style.bottomMargin,
          ),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: style.radius,
            border: Border.all(color: brand.glassBorder),
            boxShadow: [
              // Black, and only black. The bar used to carry a brand bloom
              // underneath so it read as "lit"; against a bright accent that
              // bloom is the brightest thing on screen and steals rank from the
              // play button. Depth here is a shadow, which is what depth is.
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: style.elevation,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: style.radius,
            child: _Chrome(
              style: style,
              brand: brand,
              artworkTint: artworkTint,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (style.progressPlacement ==
                      MiniProgressPlacement.hairlineTop)
                    _Progress(state: state, brand: brand),
                  SizedBox(
                    height: AppSizes.miniPlayerHeight,
                    child: _Row(
                      style: style,
                      state: state,
                      track: track,
                      brand: brand,
                    ),
                  ),
                  if (style.progressPlacement ==
                      MiniProgressPlacement.hairlineBottom)
                    _Progress(state: state, brand: brand),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The fill behind the bar — frosted or flat, depending on the variant.
///
/// Split out so the blur is constructed only when a variant actually asks for
/// it. A `BackdropFilter` with a zero-sigma blur is not free: it still forces
/// a `saveLayer` on every frame, which is exactly the cost the flat variants
/// exist to avoid.
class _Chrome extends StatelessWidget {
  const _Chrome({
    required this.style,
    required this.brand,
    required this.artworkTint,
    required this.child,
  });

  final MiniPlayerStyle style;
  final AurixPalette brand;
  final AlbumPalette? artworkTint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // The frosted fill, plus a whisper of the artwork's own brightness bleeding
    // in from the left — already greyscale by the time it reaches here, so it
    // lifts the tone under the cover without introducing a colour.
    final base = artworkTint == null
        ? brand.player
        : Color.lerp(artworkTint!.base, brand.player, 0.55)!;

    // The player role, not the surface role: this is the one surface an
    // operator is expected to want different from the rest of the app.
    final decorated = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            base.withValues(alpha: style.frosted ? 0.72 : 1),
            brand.player.withValues(alpha: style.frosted ? 0.66 : 1),
          ],
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ),
      ),
      child: child,
    );

    if (!style.frosted) return decorated;

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
      child: decorated,
    );
  }
}

/// The row itself: artwork, text, transport. Identical in every variant.
class _Row extends ConsumerWidget {
  const _Row({
    required this.style,
    required this.state,
    required this.track,
    required this.brand,
  });

  final MiniPlayerStyle style;
  final AurixPlaybackState state;
  final Track track;
  final AurixPalette brand;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playerControllerProvider.notifier);
    final text = Theme.of(context).textTheme;

    return Row(
      children: [
        SizedBox(width: style.horizontalMargin == 0 ? 0 : AppSpacing.sm),
        Hero(
          tag: MiniPlayer.artworkHeroTag,
          child: AppArtwork(
            imageUrl: track.thumbnailUrl,
            size: style.artworkSize,
            seed: track.id,
            borderRadius: style.artworkRadius,
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
                style: text.titleSmall,
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
                        style: text.labelMedium?.copyWith(
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
                        style: text.bodySmall?.copyWith(fontSize: 11.5),
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
          icon: state.isPlaying ? AurixGlyph.pause : AurixGlyph.play,
          tooltip: state.isPlaying ? 'Pause' : 'Play',
          enabled: state.mode.isPlayable || state.mode == PlaybackMode.idle,
          busy: state.isBuffering,
          onTap: controller.togglePlayPause,
        ),
        if (style.showsNextButton)
          _MiniControl(
            icon: AurixGlyph.skipNext,
            tooltip: 'Next',
            enabled: state.queue.hasNext,
            onTap: () => controller.next(),
          ),
        const SizedBox(width: AppSpacing.xs),
      ],
    );
  }
}

/// The only part of the bar that tracks the position, and the only part cheap
/// enough to: two pixels of solid colour, rebuilt inside its own `Consumer` so
/// the blur above it is untouched.
class _Progress extends ConsumerWidget {
  const _Progress({required this.state, required this.brand});

  final AurixPlaybackState state;
  final AurixPalette brand;

  @override
  Widget build(BuildContext context, WidgetRef ref) => HairlineProgress(
    progress: ref.watch(playbackProgressProvider),
    color: state.mode == PlaybackMode.unavailable
        ? brand.textTertiary
        : brand.accent,
  );
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

/// Marks that only a short excerpt is playing.
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
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontSize: 8.5,
          letterSpacing: 0.2,
          color: palette.textSecondary,
        ),
      ),
    );
  }
}
