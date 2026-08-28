import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/router/app_router.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/theme/player_themes.dart';
import '../../core/theme/theme_config.dart';
import '../../core/theme/theme_controller.dart';
import '../../data/models/track.dart';
import '../../playback/playback_mode.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/controls/music_progress_bar.dart';
import '../../shared/widgets/effects/reveal.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import 'providers/dynamic_island_provider.dart';
import 'widgets/island_skin.dart';
import 'widgets/island_waveform.dart';

/// Mounts the Dynamic Island above the whole app.
///
/// Installed from `MaterialApp.router`'s `builder`, which puts it *outside* the
/// router's `Navigator` — so the island survives every push, pop and tab
/// switch, and floats over modal routes rather than being covered by them.
/// Nothing else in AURIX can do that: a widget inside the shell disappears the
/// moment a detail route is pushed over it.
///
/// ## What is available up here
///
/// Being above the `Navigator` costs the things a route takes for granted.
/// `Theme`, `MediaQuery` and `Directionality` are present — `MaterialApp` runs
/// its builder inside all three — but `Material` and `Overlay` are not, and
/// both are load-bearing in ways that are easy to miss:
///
///  * No `Material` means no inherited `DefaultTextStyle`, so every label
///    renders with Flutter's unstyled-text warning decoration. Setting an
///    explicit style does *not* clear it. [DynamicIslandSlot] supplies a
///    transparent `Material` to fix this for the whole island.
///  * No `Overlay` means no `Tooltip`; the controls carry `Semantics` labels
///    instead.
///
/// Navigation goes through the router object rather than through `context`,
/// for the same reason: `context.pushNamed` has no `GoRouter` to find here.
class DynamicIslandLayer extends ConsumerWidget {
  const DynamicIslandLayer({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The feature switch is read first, alone, and an "off" answer hands the
    // app back untouched.
    //
    // The ordering is the entire cost story for a disabled island. Because this
    // is the only provider watched on the way out, Riverpod never subscribes
    // this element to playback or to sign-in, nothing below is built, and the
    // router listener further down is never attached — so an island the user
    // has switched off costs one boolean read per rebuild of this widget and
    // nothing else. No timer, no ticker, no playback-state processing.
    //
    // Folding this into [dynamicIslandActiveProvider] instead would read the
    // same and behave differently: the `ListenableBuilder` below would still be
    // mounted, still listening to the router delegate, and still rebuilding
    // this subtree on every push and pop — to decide, every time, that a
    // switched-off island stays hidden.
    if (!ref.watch(dynamicIslandEnabledProvider)) return child;

    final active = ref.watch(dynamicIslandActiveProvider);
    final router = ref.watch(routerProvider);

    return Stack(
      children: <Widget>[
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          // Route changes arrive through the delegate's own `Listenable` — the
          // same one `Router` listens to — rather than through a provider that
          // would have to be kept in step with navigation by hand.
          child: ListenableBuilder(
            listenable: router.routerDelegate,
            builder: (context, _) {
              final path = currentTopLocation(router);
              return DynamicIslandSlot(
                visible: active && !islandSuppressingRoutes.contains(path),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Positions the island under the device's own hardware and animates it in.
///
/// Separated from [DynamicIslandLayer] because this — not the pill — is where
/// the "works on every phone" promise actually lives, and it is worth being
/// able to mount it against a fabricated safe area to prove it.
class DynamicIslandSlot extends StatelessWidget {
  const DynamicIslandSlot({required this.visible, super.key});

  final bool visible;

  /// Applied when the platform reports no top inset at all — a flat-topped
  /// phone, a tablet, the web. Without it the pill would sit flush against the
  /// screen edge, which is the one place a floating element must never be.
  static const double _minTopInset = 12;

  @override
  Widget build(BuildContext context) {
    // This is the whole "works on every phone" story, and it is deliberately
    // one line: whatever the platform reserves at the top — a Dynamic Island,
    // a notch, a punch-hole, a status bar, nothing — the pill hangs just below
    // it. No device model is detected and no cutout is measured, so there is no
    // list of handsets to keep up to date.
    final top = math.max(MediaQuery.paddingOf(context).top, _minTopInset) +
        AppSpacing.xs + 2;

    return Padding(
      padding: EdgeInsets.only(top: top),
      child: Align(
        alignment: Alignment.topCenter,
        // Above the Navigator there is no `Material`, and a `Text` with no
        // Material ancestor inherits Flutter's unstyled-text warning
        // decoration — the yellow double underline. Every label here sets its
        // own style, but `TextStyle.merge` keeps a `decoration` the ambient
        // style supplied, so the warning survives an explicit style and shows
        // up only when the app is actually run.
        //
        // `transparency` paints nothing and clips nothing; it is here to
        // supply the inherited pieces, and it keeps the island safe for a
        // future edit that reaches for an `InkWell`.
        child: Material(
          type: MaterialType.transparency,
          child: AnimatedSwitcher(
            duration: AppConstants.medium,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.55),
                  end: Offset.zero,
                ).animate(animation),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.88, end: 1).animate(animation),
                  child: child,
                ),
              ),
            ),
            // The default builder centres children vertically, which makes the
            // outgoing pill drift down as the incoming one sizes. Pinning both
            // to the top keeps the swap in place.
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: <Widget>[...previous, ?current],
            ),
            child:
                visible ? const DynamicIslandPill() : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// The floating music control.
///
/// ## Collapsed → expanded
///
/// One controller drives the whole morph, and the two boxes it interpolates
/// between are fixed constants rather than intrinsic sizes — interpolating
/// toward a size that is itself still being measured is what turns a morph into
/// a jump.
///
/// The spring is in the *scale*, not in the box. An overshooting curve on the
/// width would push the pill past the screen edge on a narrow phone at exactly
/// the moment it is widest; a swell applied to `Transform.scale` gives the same
/// rubber-band read with no way to overflow anything.
///
/// ## Why it does not depend on a real Dynamic Island
///
/// It never asks whether the device has one. The pill is drawn by AURIX, sized
/// by AURIX and positioned relative to the safe area, so a Pixel with a
/// punch-hole, an iPhone 11 with a notch, an iPhone 16 Pro with a cutout and a
/// flat-topped budget Android all get the identical control in the identical
/// place relative to their own hardware.
class DynamicIslandPill extends ConsumerStatefulWidget {
  const DynamicIslandPill({super.key});

  @override
  ConsumerState<DynamicIslandPill> createState() => _DynamicIslandPillState();
}

class _DynamicIslandPillState extends ConsumerState<DynamicIslandPill>
    with TickerProviderStateMixin {
  late final AnimationController _expand;
  late final AnimationController _ambient;
  late final AnimationController _surge;

  Timer? _autoCollapse;
  bool _expanded = false;

  /// Mirrors `isPlaying` so [_syncAmbient] can run outside `build`, where
  /// `ref.watch` is not available. Kept in step by `build` itself.
  bool _isPlaying = false;

  static const Duration _expandDuration = Duration(milliseconds: 420);
  static const Duration _collapseDuration = Duration(milliseconds: 300);

  /// One turn of the ambient clock: the glow breathes twice per turn and the
  /// light streak crosses once.
  static const Duration _ambientPeriod = Duration(seconds: 6);

  /// The flash fired when the track changes.
  static const Duration _surgeDuration = Duration(milliseconds: 700);

  /// How long an expanded island waits before folding itself away. Long enough
  /// to press a control without racing it, short enough that the island does
  /// not become a permanent banner.
  static const Duration _idleBeforeCollapse = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _expand = AnimationController(
      vsync: this,
      duration: _expandDuration,
      reverseDuration: _collapseDuration,
    );
    _ambient = AnimationController(vsync: this, duration: _ambientPeriod);
    _surge = AnimationController(vsync: this, duration: _surgeDuration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);

    // Reduce motion keeps every state the island can be in and removes only the
    // travel between them: expanding still works, it just arrives immediately.
    _expand
      ..duration = reduced ? Duration.zero : _expandDuration
      ..reverseDuration = reduced ? Duration.zero : _collapseDuration;

    _syncAmbient();
  }

  /// Runs the ambient clock only while something is actually playing.
  ///
  /// It used to `repeat()` for the entire life of the island, which is the life
  /// of the *session* — the island is mounted above the router and stays up
  /// from the first track until the app closes. Every turn of that clock
  /// repaints [IslandFramePainter]: two `MaskFilter.blur` passes, two gradient
  /// fills and a grain field of several hundred dots, at sixty frames a second,
  /// behind whatever screen the user was actually looking at. Paused playback
  /// bought none of it back.
  ///
  /// Now it follows playback, exactly as [IslandWaveform] already did. A paused
  /// island still reads as resting rather than as broken, because it parks on a
  /// composed frame rather than at zero.
  void _syncAmbient() {
    if (!mounted) return;
    final still = MediaQuery.disableAnimationsOf(context) || !_isPlaying;
    if (still) {
      if (_ambient.isAnimating) _ambient.stop();
      // Parked a little way in, so the still frame is a composed one rather
      // than every layer sitting at its zero point.
      if (_ambient.value == 0) _ambient.value = 0.35;
    } else if (!_ambient.isAnimating) {
      _ambient.repeat();
    }
  }

  @override
  void dispose() {
    _autoCollapse?.cancel();
    _expand.dispose();
    _ambient.dispose();
    _surge.dispose();
    super.dispose();
  }

  // ---- Interaction --------------------------------------------------------

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _expand.forward();
      _restartIdleTimer();
    } else {
      _expand.reverse();
      _autoCollapse?.cancel();
    }
  }

  void _collapse() {
    if (!_expanded) return;
    setState(() => _expanded = false);
    _expand.reverse();
    _autoCollapse?.cancel();
  }

  /// Any interaction with an expanded island buys it another four seconds —
  /// otherwise the pill folds up under the finger that is using it.
  void _restartIdleTimer() {
    _autoCollapse?.cancel();
    if (!_expanded) return;
    _autoCollapse = Timer(_idleBeforeCollapse, () {
      if (mounted) _collapse();
    });
  }

  void _openPlayer() {
    _autoCollapse?.cancel();
    // `context` here sits above the Navigator, so `context.pushNamed` has no
    // GoRouter to find. The router object does.
    ref.read(routerProvider).pushDistinct(RouteNames.player);
  }

  void _onDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity < -220) {
      _openPlayer();
    } else if (velocity > 220) {
      _collapse();
    }
  }

  // ---- Build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Timeline-agnostic: the island shows no scrubber, and its capsule is
    // painted rather than composed — a rebuild here is a full repaint of two
    // blurred RRects, two gradients and a grain field. Watching the whole state
    // ran that twice a second on top of the ambient clock below.
    final state = ref.watch(playbackStateProvider);
    final track = state.track;

    // The ambient clock follows playback, and this is where the answer arrives.
    // Assigned before the early return so a queue that empties still parks it.
    if (_isPlaying != state.isPlaying) {
      _isPlaying = state.isPlaying;
      // Deferred: `build` must not start or stop a ticker, and a controller
      // that is stopped mid-build leaves the frame it was driving half-painted.
      WidgetsBinding.instance.addPostFrameCallback((_) => _syncAmbient());
    }

    // The layer already gates on this, but the queue can empty underneath a
    // mounted island — during its own exit transition, for one.
    if (track == null) return const SizedBox.shrink();

    // The configured design for this surface. Only this variant is watched, so
    // changing the mini player's theme does not rebuild a floating window that
    // may be drawing over another app.
    //
    // Resolved before the listener below, which consults it.
    final style = DynamicPlayerStyle.of(
      ref.watch(playerVariantProvider(PlayerSurface.dynamic)),
    );

    // A new track flashes the frame and glitches the title. Registered as a
    // listener rather than compared inside `build`, because firing a controller
    // from a build is a side effect in the one place Flutter cannot tolerate.
    ref.listen<String?>(
      playerControllerProvider.select((s) => s.track?.id),
      (previous, next) {
        if (previous == null || next == null || previous == next) return;
        if (!mounted || MediaQuery.disableAnimationsOf(context)) return;
        // The quiet variant does not announce track changes. Checked here
        // rather than by damping the surge to zero, so the animation is never
        // started at all.
        if (!style.expandOnTrackChange) return;
        _surge.forward(from: 0);
      },
    );

    final media = MediaQuery.of(context);
    final palette = context.palette;
    final controller = ref.read(playerControllerProvider.notifier);

    // Never wider than the screen allows, whatever the screen is.
    final available = media.size.width - (AppSpacing.lg * 2);
    final collapsedWidth =
        math.min(available, AppSizes.islandCollapsedWidth);
    final expandedWidth = math.min(available, AppSizes.islandExpandedWidth);
    final expandedHeight =
        media.size.height < AppSizes.islandCompactViewportHeight
            ? AppSizes.islandExpandedCompactHeight
            : AppSizes.islandExpandedHeight;

    final canTransport =
        state.mode.isPlayable || state.mode == PlaybackMode.idle;

    return Semantics(
      container: true,
      label: 'Now playing: ${track.name} by ${track.artistNames}',
      hint: _expanded
          ? 'Double tap to collapse, swipe up to open the player'
          : 'Double tap to expand, swipe up to open the player',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _toggle,
        onLongPress: _openPlayer,
        onVerticalDragEnd: _onDragEnd,
        child: AnimatedBuilder(
          animation: Listenable.merge(<Listenable>[_expand, _ambient, _surge]),
          builder: (context, _) {
            final raw = _expand.value;
            // One curve in both directions, deliberately. Swapping to an
            // ease-in on the way back looks better in isolation but is
            // discontinuous when the direction changes mid-flight: at the
            // halfway point the two curves are 75 points apart, so a second tap
            // during the morph would snap the pill most of the way shut before
            // animating. This curve is symmetric, so a reversal is seamless.
            final t = Curves.easeInOutCubicEmphasized.transform(raw);

            final width = _lerp(collapsedWidth, expandedWidth, t);
            final height = _lerp(style.collapsedHeight, expandedHeight, t);
            final radius = _lerp(style.cornerRadius, 28, t);

            return Transform.scale(
              // The rubber band: a 3.5% swell that peaks halfway through the
              // morph and is gone by the time it lands.
              scale: 1 + (0.035 * math.sin(raw * math.pi)),
              child: SizedBox(
                width: width,
                height: height,
                child: IslandSkin(
                  radius: radius,
                  glow: _glow(state.isPlaying) * style.glowIntensity,
                  surge: _surgeStrength * style.glowIntensity,
                  sweep: _ambient.value,
                  intensity:
                      (state.isPlaying ? 0.95 : 0.35) * style.glowIntensity,
                  child: _IslandContent(
                    style: style,
                    t: t,
                    state: state,
                    controller: controller,
                    palette: palette,
                    canTransport: canTransport,
                    onArtworkTap: _openPlayer,
                    onControlPressed: _restartIdleTimer,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  /// The track-change flash, decaying from bright to nothing over the burst.
  ///
  /// Gated on the controller actually running, not just on its value. It rests
  /// at 0, and 0 is the *start* of the decay — so without the gate the island
  /// would sit permanently at full flash from the moment it appeared until the
  /// first time the track changed.
  double get _surgeStrength {
    if (!_surge.isAnimating) return 0;
    final remaining = 1 - _surge.value;
    return remaining * remaining * 0.55;
  }

  /// The breathing pulse. Dimmed while paused rather than switched off, so a
  /// paused island reads as resting rather than as broken.
  double _glow(bool playing) {
    final wave = 0.5 + (0.5 * math.sin(_ambient.value * math.pi * 4));
    return playing ? wave : wave * 0.3;
  }
}

/// Everything inside the capsule.
///
/// Laid out as absolute slices rather than as a `Column`, because the two rows
/// have to move independently: the top row grows in place while the transport
/// row rises from below the bottom edge and is clipped until it arrives. A
/// `Column` would have to give the transport row zero height at rest, and a
/// zero-height row of 44px buttons is a layout overflow, not a hidden control.
class _IslandContent extends StatelessWidget {
  const _IslandContent({
    required this.t,
    required this.state,
    required this.controller,
    required this.palette,
    required this.canTransport,
    required this.onArtworkTap,
    required this.onControlPressed,
    required this.style,
  });

  /// 0 collapsed, 1 expanded.
  final double t;

  final AurixPlaybackState state;
  final PlayerController controller;
  final AurixPalette palette;
  final bool canTransport;
  final VoidCallback onArtworkTap;
  final VoidCallback onControlPressed;

  /// The configured design for this surface.
  final DynamicPlayerStyle style;

  /// Height of the transport row, and how far below the capsule it parks.
  static const double _transportHeight = 52;
  static const double _transportRest = -56;
  static const double _transportInset = 10;

  /// Side margin on the progress line. Holds it clear of the capsule's rounded
  /// edge, where a full-bleed hairline would meet the curve and read as a chip
  /// out of the corner.
  static const double _progressInset = 18;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: _lerp(AppSizes.islandCollapsedHeight, 56, t),
          child: _TopRow(
            style: style,
            t: t,
            state: state,
            controller: controller,
            palette: palette,
            canTransport: canTransport,
            onArtworkTap: onArtworkTap,
            onControlPressed: onControlPressed,
          ),
        ),
        // The one part of the island that moves with the timeline, and the only
        // part cheap enough to: two pixels of solid colour in its own
        // `Consumer`, so a position tick repaints the line and leaves the
        // capsule alone. Everything around it is deliberately timeline-agnostic
        // — see the note in `_DynamicIslandPillState.build` — and subscribing
        // the pill itself to the position would undo that, repainting two
        // blurred RRects, two gradients and a grain field twice a second.
        //
        // Mounted only while expanded, so a collapsed island does no position
        // work at all. It rides the transport row's own animated offset rather
        // than a fixed inset, so it stays pinned just above the controls
        // through the morph instead of drifting across the capsule.
        if (t > 0)
          Positioned(
            left: _progressInset,
            right: _progressInset,
            bottom:
                _lerp(_transportRest, _transportInset, t) + _transportHeight + 2,
            height: 2,
            child: Opacity(
              opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
              child: Consumer(
                builder: (context, ref, _) => HairlineProgress(
                  progress: ref.watch(playbackProgressProvider),
                  // Spotify Connect reports a timeline AURIX does not drive,
                  // and an unavailable track has none at all; greying the line
                  // says "not something you are watching tick" without
                  // removing it and reflowing the card.
                  color: state.mode == PlaybackMode.unavailable
                      ? palette.textTertiary
                      : palette.accent,
                ),
              ),
            ),
          ),
        // Absent while collapsed, for the same reason the inline play button is
        // absent while expanded: controls parked off the bottom edge are still
        // announced, and an island that reads as five buttons when it shows one
        // is worse to navigate by voice than it is to look at.
        if (t > 0)
          Positioned(
            left: 0,
            right: 0,
            bottom: _lerp(_transportRest, _transportInset, t),
            height: _transportHeight,
            child: Opacity(
              // Held back until the capsule is most of the way open, so the
              // controls arrive in a box that already has room for them.
              opacity: ((t - 0.35) / 0.65).clamp(0.0, 1.0),
              child: _TransportRow(
                state: state,
                controller: controller,
                canTransport: canTransport,
                onControlPressed: onControlPressed,
              ),
            ),
          ),
      ],
    );
  }
}

class _TopRow extends StatelessWidget {
  const _TopRow({
    required this.t,
    required this.state,
    required this.controller,
    required this.palette,
    required this.canTransport,
    required this.onArtworkTap,
    required this.onControlPressed,
    required this.style,
  });

  final double t;
  final AurixPlaybackState state;
  final PlayerController controller;
  final AurixPalette palette;
  final bool canTransport;
  final VoidCallback onArtworkTap;
  final VoidCallback onControlPressed;
  final DynamicPlayerStyle style;

  /// Decode size for the cover. Fixed at the largest the island ever shows it,
  /// and scaled down visually — re-deriving `memCacheWidth` on every frame of
  /// the morph would re-decode the bitmap sixty times a second.
  static const double _artDecodeSize = 44;

  @override
  Widget build(BuildContext context) {
    final track = state.track!;
    final artSize = _lerp(34, _artDecodeSize, t);

    return Row(
      children: <Widget>[
        SizedBox(width: _lerp(6, 12, t)),
        GestureDetector(
          onTap: onArtworkTap,
          child: SizedBox.square(
            dimension: artSize,
            child: FittedBox(
              fit: BoxFit.contain,
              child: AnimatedSwitcher(
                duration: AppConstants.medium,
                switchInCurve: Curves.easeOutCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.84, end: 1).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    ),
                    child: child,
                  ),
                ),
                child: AppArtwork(
                  key: ValueKey<String>(track.id),
                  imageUrl: track.thumbnailUrl,
                  size: _artDecodeSize,
                  seed: track.id,
                  borderRadius: BorderRadius.circular(13),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm + 2),
        Expanded(child: _TrackLabel(track: track, t: t)),
        const SizedBox(width: AppSpacing.sm),
        // The two ends of the waveform are now separated by luminance rather
        // than by temperature — bars alternate between the accent and the
        // secondary grey. "warm"/"cold" keep their names because the widget's
        // job is unchanged: give adjacent bars enough difference that the row
        // reads as a spectrum instead of a picket fence.
        if (style.showsWaveform)
          IslandWaveform(
            playing: state.isPlaying,
            warm: palette.accent,
            cold: palette.textSecondary,
          ),
        // The inline play button hands its job to the transport row as the
        // island opens. Dropped from the tree once fully expanded rather than
        // merely faded to nothing: a zero-width `Opacity` still publishes its
        // semantics, so a screen reader would announce a second Play button
        // that sighted users cannot see and nobody can reach.
        if (t < 1)
          ClipRect(
            child: Align(
              alignment: Alignment.centerRight,
              widthFactor: (1 - (t * 1.4)).clamp(0.0, 1.0),
              child: Opacity(
                opacity: (1 - (t * 1.6)).clamp(0.0, 1.0),
                child: _IslandButton(
                  glyph: state.isPlaying ? AurixGlyph.pause : AurixGlyph.play,
                  label: state.isPlaying ? 'Pause' : 'Play',
                  enabled: canTransport,
                  busy: state.isBuffering,
                  iconSize: 24,
                  onTap: () {
                    onControlPressed();
                    controller.togglePlayPause();
                  },
                ),
              ),
            ),
          ),
        SizedBox(width: _lerp(6, 14, t)),
      ],
    );
  }
}

/// Title, and the artist line that unfolds beneath it.
class _TrackLabel extends StatelessWidget {
  const _TrackLabel({required this.track, required this.t});

  final Track track;
  final double t;

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);

    // The island's own container already announces "Now playing: <title> by
    // <artist>". Left to itself the label here would repeat that.
    return ExcludeSemantics(
      child: SoftReveal(
        trigger: track.id,
        enabled: !reduced,
        duration: AppConstants.medium,
        // Barely any travel. The island is ~36px tall when collapsed, so the
        // full 8px settle would push the label past its own bounds.
        maxOffset: 2.2,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            AnimatedSwitcher(
              duration: AppConstants.medium,
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.5),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              layoutBuilder: (current, previous) => Stack(
                alignment: Alignment.centerLeft,
                children: <Widget>[...previous, ?current],
              ),
              child: Text(
                track.name,
                key: ValueKey<String>(track.id),
                style: AppTypography.titleSmall.copyWith(
                  fontSize: _lerp(13.5, 15, t),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            // Unfolds rather than fades: an artist line that appeared at full
            // height would shove the title up by half its own leading. Absent
            // entirely while collapsed, so nothing is laid out at zero height
            // for the sake of being invisible.
            if (t > 0)
              ClipRect(
                child: Align(
                  alignment: Alignment.topLeft,
                  heightFactor: t,
                  child: Opacity(
                    opacity: t,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        track.artistNames,
                        style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TransportRow extends StatelessWidget {
  const _TransportRow({
    required this.state,
    required this.controller,
    required this.canTransport,
    required this.onControlPressed,
  });

  final AurixPlaybackState state;
  final PlayerController controller;
  final bool canTransport;
  final VoidCallback onControlPressed;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        _IslandButton(
          glyph: AurixGlyph.skipPrevious,
          label: 'Previous',
          enabled: canTransport,
          iconSize: 24,
          onTap: () {
            onControlPressed();
            controller.previous();
          },
        ),
        const SizedBox(width: AppSpacing.xxl),
        _IslandButton(
          glyph: state.isPlaying ? AurixGlyph.pause : AurixGlyph.play,
          label: state.isPlaying ? 'Pause' : 'Play',
          enabled: canTransport,
          busy: state.isBuffering,
          filled: true,
          iconSize: 24,
          hitSize: 46,
          onTap: () {
            onControlPressed();
            controller.togglePlayPause();
          },
        ),
        const SizedBox(width: AppSpacing.xxl),
        _IslandButton(
          glyph: AurixGlyph.skipNext,
          label: 'Next',
          enabled: state.queue.hasNext,
          iconSize: 24,
          onTap: () {
            onControlPressed();
            controller.next();
          },
        ),
      ],
    );
  }
}

/// A transport control for the island.
///
/// Hand-built rather than an `IconButton` for two reasons: `Tooltip` needs an
/// `Overlay`, which does not exist outside the `Navigator`, and a ripple
/// spreading across dark glass reads as a smear. The press feedback is a scale
/// instead, which is closer to how the control it is imitating behaves anyway.
class _IslandButton extends StatefulWidget {
  const _IslandButton({
    required this.glyph,
    required this.label,
    required this.onTap,
    this.enabled = true,
    this.busy = false,
    this.filled = false,
    this.iconSize = 24,
    this.hitSize = 40,
  });

  final AurixGlyph glyph;

  /// Announced by screen readers, since there is no tooltip to carry it.
  final String label;

  final VoidCallback onTap;
  final bool enabled;
  final bool busy;

  /// Draws the button as a filled brand disc — the primary action in the
  /// expanded transport row.
  final bool filled;

  final double iconSize;
  final double hitSize;

  @override
  State<_IslandButton> createState() => _IslandButtonState();
}

class _IslandButtonState extends State<_IslandButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    Widget content;
    if (widget.busy) {
      content = SizedBox.square(
        dimension: widget.iconSize * 0.7,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: widget.filled ? palette.textOnAccent : context.palette.textPrimary,
        ),
      );
    } else {
      content = AnimatedSwitcher(
        duration: AppConstants.fast,
        child: AurixIcon(
          widget.glyph,
          key: ValueKey<AurixGlyph>(widget.glyph),
          size: widget.iconSize,
          color: widget.filled
              ? palette.textOnAccent
              : (widget.enabled
                    ? context.palette.textPrimary
                    : context.palette.textTertiary),
        ),
      );
    }

    if (widget.filled) {
      content = DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: palette.accentGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: palette.glow(widget.enabled ? 0.42 : 0.12),
              blurRadius: 14,
              spreadRadius: -2,
            ),
          ],
        ),
        child: Center(child: content),
      );
      content = Opacity(opacity: widget.enabled ? 1 : 0.45, child: content);
    }

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.enabled ? (_) => _setPressed(true) : null,
        onTapUp: widget.enabled ? (_) => _setPressed(false) : null,
        onTapCancel: () => _setPressed(false),
        onTap: widget.enabled && !widget.busy ? widget.onTap : null,
        child: AnimatedScale(
          scale: _pressed ? 0.86 : 1,
          duration: AppConstants.fast,
          curve: Curves.easeOutCubic,
          child: SizedBox.square(
            dimension: widget.hitSize,
            child: widget.filled ? content : Center(child: content),
          ),
        ),
      ),
    );
  }
}

/// Linear interpolation between two values that are never null, so the island's
/// geometry does not thread `dart:ui`'s nullable `lerpDouble` through every
/// dimension it animates.
double _lerp(double a, double b, double t) => a + ((b - a) * t);
