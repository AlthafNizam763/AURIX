import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/error_mapper.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/album_palette.dart';
import '../../core/utils/responsive.dart';
import '../../core/utils/share_helper.dart';
import '../../data/models/playback.dart';
import '../../data/models/track.dart';
import '../../playback/playback_mode.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/controls/music_progress_bar.dart';
import '../../shared/widgets/controls/play_button.dart';
import '../../shared/widgets/effects/grain.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../album/providers/detail_providers.dart';
import '../auth/providers/auth_provider.dart';
import '../library/providers/saved_tracks_provider.dart';
import '../shell/widgets/mini_player.dart';
import 'widgets/lyrics_view.dart';
import 'widgets/playback_notice.dart';

/// The full-screen player.
///
/// The background gradient is derived from the current artwork, with a blurred
/// copy of the cover behind it — which is what makes the screen feel like it
/// belongs to the song rather than to the app.
class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  @override
  void initState() {
    super.initState();
    // Device availability goes stale fast (a laptop closing removes one), so
    // re-check on open rather than trusting whatever was cached.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(playerControllerProvider.notifier).refreshDevices(force: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Timeline-agnostic. This screen stacks the most expensive composition in
    // the app — a full-bleed 60-sigma blur of the artwork, a greyscale colour
    // filter over it, an animated gradient and a grain painter — and watching
    // the full state rebuilt all of it twice a second while a track played.
    // Only the scrubber needs the position, and `_ProgressSection` subscribes
    // to it on its own.
    final state = ref.watch(playbackStateProvider);
    final track = state.track;

    if (track == null) {
      // Reachable if the queue empties while the player is open.
      return const _EmptyPlayer();
    }

    final palette = watchPalette(ref, track.artworkUrl);

    // Surface any transient error once, then clear it, so it does not persist
    // across track changes.
    ref.listen<AurixPlaybackState>(playerControllerProvider, (previous, next) {
      final message = next.errorMessage;
      if (message == null || message == previous?.errorMessage) return;
      AppSnackbar.error(context, message);
      ref.read(playerControllerProvider.notifier).dismissError();
    });

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _Backdrop(
            imageUrl: track.artworkUrl,
            palette: palette,
            isPlaying: state.isPlaying,
          ),
          SafeArea(
            child: context.isLandscape
                ? _LandscapeLayout(state: state, track: track, palette: palette)
                : _PortraitLayout(state: state, track: track, palette: palette),
          ),
        ],
      ),
    );
  }
}

/// Blurred artwork under a palette gradient, with the Spider-Verse ambience
/// drifting over it.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.imageUrl,
    required this.palette,
    required this.isPlaying,
  });

  final String? imageUrl;
  final AlbumPalette palette;
  final bool isPlaying;

  @override
  Widget build(BuildContext context) {
    final brand = context.palette;

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: brand.ground),

        // The artwork wash — desaturated.
        //
        // This is the single most important colour decision on the screen. The
        // cover itself keeps its colour a few hundred pixels above: it is
        // *content*, and stripping it would be vandalism. But blurred to 60
        // sigma and stretched full-bleed, the same image stops being content
        // and becomes background — and a background is UI, which AURIX does not
        // let hold a hue. Left in colour, a magenta sleeve turns the entire
        // player magenta and the identity is simply gone for as long as that
        // track plays.
        //
        // Greyscaling it is what produces the effect the whole design is
        // built around: one saturated object, sharp, on a monochrome field
        // derived from itself.
        if (imageUrl != null)
          ColorFiltered(
            colorFilter: const ColorFilter.matrix(_greyscaleMatrix),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Opacity(
                opacity: 0.55,
                child: AppArtwork(
                  imageUrl: imageUrl,
                  size: MediaQuery.sizeOf(context).longestSide,
                  borderRadius: BorderRadius.zero,
                ),
              ),
            ),
          ),

        AnimatedContainer(
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: palette
                  .playerGradient(brand)
                  .map((c) => c.withValues(alpha: 0.88))
                  .toList(),
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),

        // Sinks the whole field toward the page colour, heaviest at the bottom
        // where the controls live. The middle stop is deliberately the lightest
        // of the three: it keeps a band of the artwork's own brightness alive
        // behind the cover instead of flattening the screen to one tone.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                brand.ground.withValues(alpha: 0.42),
                brand.ground.withValues(alpha: 0.20),
                brand.ground.withValues(alpha: 0.88),
              ],
              stops: const [0, 0.45, 1],
            ),
          ),
        ),

        // Grain over everything, fading from the top so it stays off the
        // controls at the bottom where texture behind small text is just noise.
        //
        // Load-bearing here rather than decorative: this screen stacks four
        // translucent layers of near-black, which is exactly where 8-bit
        // gradients band into visible steps.
        IgnorePointer(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: GrainPainter(
                color: brand.grain,
                fade: GrainFade.top,
                // A touch stronger while playing. It is the only thing on the
                // backdrop that still responds to playback now that the
                // animated layer is gone, and at this alpha it registers as
                // presence rather than as motion.
                opacity: isPlaying ? 1 : 0.6,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Rec. 709 luminance in all three output rows: every channel becomes the
/// perceived brightness of the pixel.
///
/// Not `saturation: 0` on a `ColorFilter.matrix` cousin, and not an HSL
/// desaturation — both of those weight the channels equally, which renders
/// saturated blues far too light and saturated greens far too dark. The same
/// reasoning as `AlbumPalette`, applied to whole images instead of one swatch.
const List<double> _greyscaleMatrix = <double>[
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0.2126, 0.7152, 0.0722, 0, 0,
  0, 0, 0, 1, 0,
];

class _PortraitLayout extends ConsumerWidget {
  const _PortraitLayout({
    required this.state,
    required this.track,
    required this.palette,
  });

  final AurixPlaybackState state;
  final Track track;
  final AlbumPalette palette;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artSize = context.playerArtworkSize;

    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Column(
        children: [
          _PlayerTopBar(state: state, track: track),
          const Spacer(flex: 2),
          Hero(
            tag: MiniPlayer.artworkHeroTag,
            child: AppArtwork(
              imageUrl: track.artworkUrl,
              size: artSize,
              seed: track.id,
              borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
              elevated: true,
            ),
          ),
          // Lyrics take the flexible gap between the cover and the title rather
          // than adding a height of their own — the column has no budget left,
          // and anything with a fixed height here comes out of the artwork. On a
          // track with no lyrics this renders one muted line, and on a short
          // viewport it clips instead of overflowing. See [LyricsStrip].
          const Expanded(flex: 2, child: LyricsStrip()),
          _TrackTitle(track: track),
          const SizedBox(height: AppSpacing.xl),
          _ProgressSection(state: state),
          const SizedBox(height: AppSpacing.md),
          _TransportRow(state: state),
          const SizedBox(height: AppSpacing.lg),
          PlaybackNotice(state: state),
          const SizedBox(height: AppSpacing.sm),
          _BottomBar(state: state, track: track),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}

/// Landscape puts artwork beside the controls instead of squeezing a
/// portrait column into a 400px-tall viewport.
class _LandscapeLayout extends ConsumerWidget {
  const _LandscapeLayout({
    required this.state,
    required this.track,
    required this.palette,
  });

  final AurixPlaybackState state;
  final Track track;
  final AlbumPalette palette;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
      child: Column(
        children: [
          _PlayerTopBar(state: state, track: track),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Hero(
                  tag: MiniPlayer.artworkHeroTag,
                  child: AppArtwork(
                    imageUrl: track.artworkUrl,
                    size: context.playerArtworkSize,
                    seed: track.id,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(AppRadius.md),
                    ),
                    elevated: true,
                  ),
                ),
                const SizedBox(width: AppSpacing.xxxl),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _TrackTitle(track: track),
                      // Bounded and flexible: landscape has far less vertical
                      // room, so the strip gives way to the transport controls
                      // rather than pushing them off the screen.
                      // Not `const`: ConstrainedBox asserts its constraints are
                      // valid, so Flutter gives it no const constructor.
                      Flexible(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 84),
                          child: const LyricsStrip(),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.lg),
                      _ProgressSection(state: state),
                      const SizedBox(height: AppSpacing.sm),
                      _TransportRow(state: state),
                      const SizedBox(height: AppSpacing.md),
                      PlaybackNotice(state: state),
                      _BottomBar(state: state, track: track),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PlayerTopBar extends ConsumerWidget {
  const _PlayerTopBar({required this.state, required this.track});

  final AurixPlaybackState state;
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final context0 = state.context;

    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const AurixIcon(AurixGlyph.chevronDown, size: 30),
          tooltip: 'Close',
        ),
        Expanded(
          child: Column(
            children: [
              Text(
                context0.uri == null ? 'PLAYING FROM' : 'PLAYING FROM',
                style: AppTypography.labelSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                context0.title,
                style: AppTypography.titleSmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: () => _showMenu(context, ref),
          icon: const AurixIcon(AurixGlyph.moreVertical),
          tooltip: 'More options',
        ),
      ],
    );
  }

  void _showMenu(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playerControllerProvider.notifier);
    final artist = track.primaryArtist;

    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl,
      note: _noteFor(state),
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'View queue',
          onTap: () => context.pushDistinct(RouteNames.queue),
        ),
        SheetAction(
          icon: AurixGlyph.devices,
          label: 'Connect to a device',
          subtitle: state.activeDevice?.name,
          onTap: () => context.pushDistinct(RouteNames.devices),
        ),
        if (artist != null)
          SheetAction(
            icon: AurixGlyph.profile,
            label: 'Go to artist',
            onTap: () => context.pushDistinct(
              RouteNames.artist,
              pathParameters: {'id': artist.id},
            ),
          ),
        if (track.album != null)
          SheetAction(
            icon: AurixGlyph.album,
            label: 'Go to album',
            onTap: () => context.pushDistinct(
              RouteNames.album,
              pathParameters: {'id': track.album!.id},
            ),
          ),
        SheetAction(
          icon: AurixGlyph.share,
          label: 'Share',
          onTap: () => ShareHelper.share(
            context,
            kind: ShareKind.track,
            id: track.id,
            name: track.name,
            subtitle: track.artistNames,
            spotifyUrl: track.spotifyUrl,
          ),
        ),
        SheetAction(
          icon: AurixGlyph.trash,
          label: 'Clear up next',
          enabled: state.queue.upNext.isNotEmpty,
          onTap: controller.clearUpNext,
        ),
      ],
    );
  }

  String? _noteFor(AurixPlaybackState state) {
    switch (state.mode) {
      case PlaybackMode.preview:
        return 'Playing Spotify\'s 30-second preview on this device. '
            'Connect a Spotify device to hear the full track.';
      case PlaybackMode.connect:
        final device = state.activeDevice?.name;
        return device == null
            ? 'Playing through Spotify Connect.'
            : 'Playing on $device through Spotify Connect.';
      case PlaybackMode.appRemote:
        return 'Playing the full track in the Spotify app on this device.';
      case PlaybackMode.unavailable:
        return state.limitation?.detail;
      case PlaybackMode.idle:
        return null;
    }
  }
}

class _TrackTitle extends ConsumerWidget {
  const _TrackTitle({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artist = track.primaryArtist;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                track.name,
                style: track.name.length > 26
                    ? AppTypography.headlineMedium
                    : AppTypography.headlineLarge,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              GestureDetector(
                onTap: artist == null
                    ? null
                    : () => context.pushDistinct(
                        RouteNames.artist,
                        pathParameters: {'id': artist.id},
                      ),
                child: Text(
                  track.artistNames,
                  style: AppTypography.bodyLarge.copyWith(
                    color: context.palette.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        _SaveTrackButton(track: track),
      ],
    );
  }
}

/// The player's heart.
///
/// Reads and writes the one shared store rather than holding a `bool?` of its
/// own. That is what makes liking here fill the same track's heart in the
/// playlist underneath and drop the row into Liked Songs, instead of the two
/// disagreeing until the screen was rebuilt from scratch.
class _SaveTrackButton extends ConsumerStatefulWidget {
  const _SaveTrackButton({required this.track});

  final Track track;

  @override
  ConsumerState<_SaveTrackButton> createState() => _SaveTrackButtonState();
}

class _SaveTrackButtonState extends ConsumerState<_SaveTrackButton> {
  @override
  void initState() {
    super.initState();
    _request();
  }

  @override
  void didUpdateWidget(_SaveTrackButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The player outlives any one song, so a track change needs a fresh ask.
    if (oldWidget.track.id != widget.track.id) _request();
  }

  /// Called from the lifecycle rather than from `build`. A membership lookup
  /// fired during the build phase is a side effect in the one place Flutter
  /// cannot tolerate one, and this screen rebuilds on every track change.
  /// The store answers from cache when it already knows.
  void _request() {
    ref.read(savedTracksProvider.notifier).ensureKnown(<String>[widget.track.id]);
  }

  @override
  Widget build(BuildContext context) {
    // Null until the store has an answer — the heart stays disabled rather than
    // rendering empty, because an empty heart is a claim about the user's
    // library.
    final isSaved = ref.watch(isTrackSavedProvider(widget.track.id));

    return LikeButton(
      isSaved: isSaved ?? false,
      size: 28,
      enabled: isSaved != null,
      onToggle: _toggle,
    );
  }

  Future<void> _toggle() async {
    try {
      await ref.read(savedTracksProvider.notifier).toggle(widget.track);
    } on Object catch (error) {
      // Never silent: the store has already rolled the heart back, and a 403
      // from Spotify is something the user needs told rather than a heart that
      // mysteriously refuses to stay filled.
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }
}

/// The scrubber, and the only thing on this screen that repaints at tick rate.
///
/// It watches the position itself rather than taking it from the screen's
/// state, so the blurred backdrop above it does not have to rebuild for the
/// thumb to move.
class _ProgressSection extends ConsumerWidget {
  const _ProgressSection({required this.state});

  final AurixPlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final timeline = ref.watch(playbackTimelineProvider);

    return MusicProgressBar(
      position: timeline.position,
      duration: timeline.duration,
      enabled: state.mode.isPlayable,
      onSeek: ref.read(playerControllerProvider.notifier).seek,
      // Stated explicitly so nobody mistakes a 30-second bar for the full song.
      previewNotice: state.isPreviewOnly
          ? 'Spotify preview — 30 seconds of ${_fullLength(state)}'
          : null,
    );
  }

  String _fullLength(AurixPlaybackState state) {
    final full = state.track?.duration;
    if (full == null) return 'the full track';
    final minutes = full.inMinutes;
    final seconds = full.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TransportRow extends ConsumerWidget {
  const _TransportRow({required this.state});

  final AurixPlaybackState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(playerControllerProvider.notifier);
    final repeat = state.repeatMode;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        TransportButton(
          icon: AurixGlyph.shuffle,
          tooltip: state.shuffled ? 'Shuffle on' : 'Shuffle off',
          active: state.shuffled,
          size: 24,
          onPressed: controller.toggleShuffle,
        ),
        TransportButton(
          icon: AurixGlyph.skipPrevious,
          tooltip: 'Previous',
          size: 40,
          enabled: state.queue.isNotEmpty,
          onPressed: controller.previous,
        ),
        PlayButton(
          isPlaying: state.isPlaying,
          isLoading: state.isBuffering,
          enabled: state.mode != PlaybackMode.unavailable,
          size: 68,
          onPressed: controller.togglePlayPause,
        ),
        TransportButton(
          icon: AurixGlyph.skipNext,
          tooltip: 'Next',
          size: 40,
          enabled: state.queue.hasNext,
          onPressed: () => controller.next(),
        ),
        TransportButton(
          icon: repeat == RepeatState.track
              ? AurixGlyph.repeatOne
              : AurixGlyph.repeatAll,
          tooltip: switch (repeat) {
            RepeatState.off => 'Repeat off',
            RepeatState.context => 'Repeat queue',
            RepeatState.track => 'Repeat song',
          },
          active: repeat != RepeatState.off,
          size: 24,
          onPressed: controller.cycleRepeat,
        ),
      ],
    );
  }
}

class _BottomBar extends ConsumerWidget {
  const _BottomBar({required this.state, required this.track});

  final AurixPlaybackState state;
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = state.activeDevice;
    final isConnect = state.mode == PlaybackMode.connect;
    // "This device" is only honest when Spotify has said Connect is off the
    // table. When it simply did not report the tier, offering the picker is
    // the useful default — it is where the "open Spotify somewhere" guidance
    // lives, and Connect may well work.
    final knownNonPremium = ref.watch(knownNonPremiumProvider);

    return Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: () => context.pushDistinct(RouteNames.devices),
            icon: AurixIcon(
              isConnect ? AurixGlyph.devices : AurixGlyph.phone,
              size: 18,
              color: isConnect ? context.palette.accent : context.palette.textSecondary,
            ),
            label: Text(
              device?.name ?? (knownNonPremium ? 'This device' : 'Choose a device'),
              style: AppTypography.labelMedium.copyWith(
                color: isConnect ? context.palette.accent : context.palette.textSecondary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: TextButton.styleFrom(
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.zero,
            ),
          ),
        ),
        IconButton(
          onPressed: () => ShareHelper.share(
            context,
            kind: ShareKind.track,
            id: track.id,
            name: track.name,
            subtitle: track.artistNames,
            spotifyUrl: track.spotifyUrl,
          ),
          icon: const AurixIcon(AurixGlyph.share, size: 20),
          tooltip: 'Share',
          color: context.palette.textSecondary,
        ),
        IconButton(
          onPressed: () => context.pushDistinct(RouteNames.queue),
          icon: const AurixIcon(AurixGlyph.playlist, size: 22),
          tooltip: 'Queue',
          color: context.palette.textSecondary,
        ),
      ],
    );
  }
}

class _EmptyPlayer extends StatelessWidget {
  const _EmptyPlayer();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.ground,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const AurixIcon(AurixGlyph.chevronDown, size: 30),
        ),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AurixIcon(AurixGlyph.musicNote, size: 48, color: context.palette.textTertiary),
              const SizedBox(height: AppSpacing.lg),
              const Text('Nothing playing', style: AppTypography.headlineSmall),
              const SizedBox(height: AppSpacing.sm),
              const Text(
                'Pick a song from Home, Search or your Library to start.',
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
