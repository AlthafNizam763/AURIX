import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../icons/aurix_glyphs.dart';
import '../icons/aurix_icon.dart';

/// The AURIX play/pause emblem — the app's single most recognisable control.
///
/// A solid white disc carrying a black glyph. Nothing else on screen is a
/// filled white shape, which is the entire mechanism: in a palette with one
/// accent, scarcity is the only way to rank anything. The button does not need
/// to be loud because it is the sole occurrence.
///
/// This replaced a gradient "neon ring" wrapping a dark disc. That design was
/// solving a problem this palette does not have — with two brand hues to spend,
/// an outlined button let both appear at once. With one accent an outline is
/// strictly worse than a fill: it reads as secondary next to any filled
/// element, and secondary is the opposite of what the primary control needs.
///
/// Pressing it dips the disc ~4% and sends one thin ring outward. Both are
/// suppressed under "reduce motion", where the control still works and simply
/// does not animate.
///
/// The icon crossfades rather than swapping instantly — a hard swap on a 56px
/// control reads as a flicker at 60fps.
class PlayButton extends StatefulWidget {
  const PlayButton({
    required this.isPlaying,
    required this.onPressed,
    this.size = 56,
    this.isLoading = false,
    this.enabled = true,
    this.tooltip,
    super.key,
  });

  final bool isPlaying;
  final VoidCallback? onPressed;
  final double size;
  final bool isLoading;
  final bool enabled;
  final String? tooltip;

  /// Below this the disc is small enough that the resting halo bleeds past its
  /// own edge and reads as a smudge, so it is skipped. The fill alone still
  /// carries the identity at small sizes.
  static const double haloThreshold = 48;

  @override
  State<PlayButton> createState() => _PlayButtonState();
}

class _PlayButtonState extends State<PlayButton>
    with TickerProviderStateMixin {
  late final AnimationController _burst;
  late final AnimationController _pulse;

  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    // Both built in initState rather than as lazy `late final`s: under "reduce
    // motion" neither `build` nor the tap handler ever touches them, so a lazy
    // field would be constructed for the first time inside `dispose()` —
    // creating a Ticker against a deactivated element. See the matching note
    // in `GlitchBurst`.
    _burst = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 540),
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(PlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying ||
        widget.enabled != oldWidget.enabled) {
      _syncPulse();
    }
  }

  /// The resting pulse runs only while a track is actually playing.
  ///
  /// A control that breathes while nothing is happening is worse than a still
  /// one: it implies activity the app is not performing, and it keeps a ticker
  /// alive on every screen the button appears on.
  void _syncPulse() {
    final shouldPulse = widget.isPlaying &&
        widget.enabled &&
        widget.onPressed != null &&
        !MediaQuery.disableAnimationsOf(context);

    if (shouldPulse && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!shouldPulse && _pulse.isAnimating) {
      _pulse
        ..stop()
        // Settled at rest rather than frozen mid-breath, so pausing does not
        // leave the glow stuck at an arbitrary strength.
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _burst.dispose();
    _pulse.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  void _handleTap(bool animate) {
    // The burst fires on *every* press, including pause. It reads as the
    // control acknowledging the touch, not as a "started playing" signal —
    // tying it to play only would make pause feel unresponsive by comparison.
    if (animate) _burst.forward(from: 0);
    widget.onPressed?.call();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.enabled && widget.onPressed != null;
    final palette = context.palette;
    final animate = !MediaQuery.disableAnimationsOf(context);
    final label = widget.tooltip ?? (widget.isPlaying ? 'Pause' : 'Play');

    // Everything inside the disc is ink-on-accent, not ink-on-page: the glyph,
    // the spinner and the disabled state all sit *on* white. Using the page's
    // text colours here would paint white on white.
    final onDisc = active ? palette.textOnAccent : palette.textTertiary;

    final glyph = widget.isLoading
        ? Padding(
            padding: EdgeInsets.all(widget.size * 0.3),
            child: CircularProgressIndicator(strokeWidth: 2.4, color: onDisc),
          )
        : AnimatedSwitcher(
            duration: AppConstants.fast,
            transitionBuilder: (child, animation) => ScaleTransition(
              scale: animation,
              child: FadeTransition(opacity: animation, child: child),
            ),
            child: AurixIcon(
              widget.isPlaying ? AurixGlyph.pause : AurixGlyph.play,
              key: ValueKey(widget.isPlaying),
              size: widget.size * 0.46,
              color: onDisc,
            ),
          );

    // The resting breath, rebuilt only inside this subtree — the glyph and the
    // burst above it are passed through as `child` so they are not rebuilt
    // sixty times a second for a glow that is barely moving.
    final emblem = AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        // A slow swell on a very faint halo. The alpha ceiling here is roughly
        // a fifth of what the previous neon emblem used, and that restraint is
        // the difference between "premium" and "gaming peripheral": a white
        // disc that visibly glows on black looks backlit, and backlit reads as
        // cheap. At these values the halo is not seen as light — it is seen as
        // the disc sitting slightly above the page.
        final breath = Curves.easeInOut.transform(_pulse.value);
        final lift = active && widget.isPlaying ? breath : 0.0;
        final showHalo = active && widget.size >= PlayButton.haloThreshold;

        return DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: showHalo
                ? [
                    BoxShadow(
                      color: palette.glow(
                        _pressed ? 0.18 : 0.09 + (lift * 0.05),
                      ),
                      blurRadius:
                          widget.size * (_pressed ? 0.5 : 0.34 + (lift * 0.1)),
                      spreadRadius: widget.size * (-0.06 + (lift * 0.02)),
                    ),
                  ]
                : null,
          ),
          child: child,
        );
      },
      child: CustomPaint(
        painter: _DiscPainter(
          fill: !active
              ? palette.surfaceHighest
              : (_pressed ? palette.accentPressed : palette.accent),
          // Only drawn when the disc is *not* filled with the accent. A hairline
          // around a white disc on black does nothing; around a graphite
          // disabled disc it is what keeps the control visible at all.
          hairline: active ? null : palette.hairline,
        ),
        child: SizedBox.square(dimension: widget.size, child: Center(child: glyph)),
      ),
    );

    return Semantics(
      button: true,
      enabled: active,
      label: label,
      child: Tooltip(
        message: label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: active ? () => _handleTap(animate) : null,
          onTapDown: active && animate ? (_) => _setPressed(true) : null,
          onTapUp: active && animate ? (_) => _setPressed(false) : null,
          onTapCancel: active && animate ? () => _setPressed(false) : null,
          child: AnimatedScale(
            scale: _pressed ? 0.96 : 1,
            duration: AppConstants.fast,
            curve: Curves.easeOut,
            child: Stack(
              // The burst paints outside the button's own bounds; without this
              // it is clipped to the circle and reads as a flicker.
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                if (animate)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: OverflowBox(
                        maxWidth: widget.size * 2.4,
                        maxHeight: widget.size * 2.4,
                        child: RepaintBoundary(
                          child: AnimatedBuilder(
                            animation: _burst,
                            builder: (context, _) => CustomPaint(
                              size: Size.square(widget.size * 2.4),
                              painter: _PressRingPainter(
                                progress: _burst.value,
                                color: palette.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                emblem,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the disc: one filled circle, and a hairline only when it is not
/// filled with the accent.
///
/// Kept as a painter rather than a `DecoratedBox` so the fill and the optional
/// hairline stay concentric at every size, and so the control measures exactly
/// `size` — a `Border` would grow the box by its own width and make the button
/// disagree with its hit target.
class _DiscPainter extends CustomPainter {
  const _DiscPainter({required this.fill, this.hairline});

  final Color fill;

  /// Null when the disc is filled with the accent. See the call site.
  final Color? hairline;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final edge = math.min(size.width, size.height);
    final origin = Offset(size.width / 2, size.height / 2);
    final stroke = hairline == null ? 0.0 : 1.0;
    // Inset by half the stroke so any hairline sits *inside* the nominal
    // bounds and the control measures exactly `size` for layout.
    final radius = (edge - stroke) / 2;

    canvas.drawCircle(origin, radius, Paint()..color = fill..isAntiAlias = true);

    final border = hairline;
    if (border != null) {
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..isAntiAlias = true
          ..color = border,
      );
    }
  }

  @override
  bool shouldRepaint(_DiscPainter oldDelegate) =>
      oldDelegate.fill != fill || oldDelegate.hairline != hairline;
}

/// One thin ring travelling outward from the disc on press, then gone.
///
/// Replaced a radial "web burst". The ring is deliberately the least
/// interesting shape available: press feedback has to be read peripherally —
/// the user is looking at the glyph, not at the effect — and anything with
/// structure demands a look it does not deserve. A circle expanding and fading
/// is legible at the edge of vision as pure motion.
///
/// It fades on a curve *ahead* of its expansion, so the ring is already almost
/// gone by the time it reaches its full radius. A ring that stays solid to the
/// end reads as a boundary the interface just drew, rather than as an impulse
/// leaving the button.
class _PressRingPainter extends CustomPainter {
  const _PressRingPainter({required this.progress, required this.color});

  /// 0 → 1 across the burst. 0 paints nothing.
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.001 || progress >= 1 || size.isEmpty) return;

    final edge = math.min(size.width, size.height);
    final origin = Offset(size.width / 2, size.height / 2);

    final eased = Curves.easeOutCubic.transform(progress);
    // Starts at the disc's own edge — the button occupies the middle ~42% of
    // this oversized canvas — and travels to just inside the bounds.
    final radius = edge * (0.21 + (0.26 * eased));
    final alpha = (1 - Curves.easeOutQuart.transform(progress)) * 0.42;

    if (alpha <= 0.004) return;

    canvas.drawCircle(
      origin,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, edge * 0.006)
        ..isAntiAlias = true
        ..color = color.withValues(alpha: alpha),
    );
  }

  @override
  bool shouldRepaint(_PressRingPainter oldDelegate) =>
      oldDelegate.progress != progress || oldDelegate.color != color;
}

/// Transport icon button (previous / next / shuffle / repeat).
///
/// [active] drives the accent tint used by shuffle and repeat when engaged —
/// the only visual cue those two controls have.
///
/// Pressing dips the glyph and lights a brand bloom behind it. Material's own
/// splash is suppressed app-wide (`highlightColor: transparent`), so without
/// this these controls acknowledged a tap with nothing at all.
class TransportButton extends StatefulWidget {
  const TransportButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 30,
    this.active = false,
    this.enabled = true,
    this.badge,
    super.key,
  });

  final AurixGlyph icon;
  final VoidCallback? onPressed;
  final String tooltip;
  final double size;
  final bool active;
  final bool enabled;

  /// Tiny superscript, used for "1" on repeat-one.
  final String? badge;

  @override
  State<TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<TransportButton> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final usable = widget.enabled && widget.onPressed != null;
    final palette = context.palette;
    final accent = palette.accent;
    final size = widget.size;

    // Shuffle and repeat previously said "engaged" by turning the accent
    // colour. That silently stopped working the moment the accent became white:
    // the resting glyph was *already* white, so the two states were identical.
    //
    // The engaged state is now the brighter of two greys, plus the icon set's
    // own emphasis mark below. Resting drops to secondary — which also makes
    // the transport row sit back from the play button, as it should.
    final color = !usable
        ? palette.textTertiary
        : widget.active
            ? palette.textPrimary
            : palette.textSecondary;

    // Pointer callbacks rather than InkWell state: the icon lives inside an
    // IconButton whose own press feedback is disabled, and Listener sees the
    // down/up edges without competing for the gesture.
    return Tooltip(
      message: widget.tooltip,
      child: Listener(
        onPointerDown: usable ? (_) => _setPressed(true) : null,
        onPointerUp: usable ? (_) => _setPressed(false) : null,
        onPointerCancel: usable ? (_) => _setPressed(false) : null,
        child: IconButton(
        onPressed: usable ? widget.onPressed : null,
        iconSize: size,
        constraints: BoxConstraints(
          minWidth: size + 16,
          minHeight: AppSizes.minTapTarget,
        ),
        icon: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            AnimatedScale(
              scale: _pressed ? 0.88 : 1,
              duration: AppConstants.fast,
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: AppConstants.fast,
                curve: Curves.easeOut,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // One faint wash on press, where there used to be two stacked
                  // coloured blooms. These controls sit *beside* the play
                  // button; anything brighter than this competes with it, and
                  // the hierarchy between primary and transport controls is the
                  // only thing keeping the player readable.
                  boxShadow: _pressed
                      ? [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.16),
                            blurRadius: size * 0.62,
                            spreadRadius: size * -0.12,
                          ),
                        ]
                      : const [],
                ),
                // Shuffle and repeat light the emphasis treatment when engaged
                // — the accent tint alone is a weak cue for a state the user is
                // trying to confirm at a glance.
                child: AurixIcon(
                  widget.icon,
                  size: size,
                  color: color,
                  emphasis: usable && widget.active,
                ),
              ),
            ),
            if (widget.badge != null)
              Positioned(
                right: -2,
                bottom: -2,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    widget.badge!,
                    style: TextStyle(
                      fontFamily: AppTypography.fontFamily,
                      fontSize: 8,
                      height: 1,
                      fontWeight: FontWeight.w800,
                      // On the badge's own fill, which is `color` above.
                      color: palette.ground,
                    ),
                  ),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

/// Outlined pill used for secondary actions on detail screens
/// (Follow, Save, Share).
class ActionPill extends StatelessWidget {
  const ActionPill({
    required this.label,
    required this.onPressed,
    this.icon,
    this.selected = false,
    this.enabled = true,
    super.key,
  });

  final String label;
  final VoidCallback? onPressed;
  final AurixGlyph? icon;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final usable = enabled && onPressed != null;
    final palette = context.palette;
    final ink = selected ? palette.textOnAccent : palette.textPrimary;

    return AnimatedContainer(
      duration: AppConstants.fast,
      child: OutlinedButton.icon(
        onPressed: usable ? onPressed : null,
        icon: switch (icon) {
          null => null,
          final glyph => AurixIcon(glyph, size: 17),
        },
        label: Text(label),
        style: OutlinedButton.styleFrom(
          foregroundColor: ink,
          backgroundColor: selected ? palette.accent : Colors.transparent,
          side: BorderSide(
            color: selected ? palette.accent : palette.hairlineStrong,
          ),
          textStyle: AppTypography.labelMedium.copyWith(
            fontWeight: FontWeight.w700,
            color: ink,
          ),
          minimumSize: const Size(0, 38),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        ),
      ),
    );
  }
}

/// The heart used for Liked Songs.
///
/// Animates a small "pop" on save, which is the confirmation users look for
/// when the network round trip has not finished yet.
class LikeButton extends StatefulWidget {
  const LikeButton({
    required this.isSaved,
    required this.onToggle,
    this.size = 26,
    this.enabled = true,
    super.key,
  });

  final bool isSaved;
  final VoidCallback? onToggle;
  final double size;
  final bool enabled;

  @override
  State<LikeButton> createState() => _LikeButtonState();
}

class _LikeButtonState extends State<LikeButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
  );

  late final Animation<double> _scale = TweenSequence<double>([
    TweenSequenceItem(tween: Tween(begin: 1, end: 1.3), weight: 40),
    TweenSequenceItem(tween: Tween(begin: 1.3, end: 1), weight: 60),
  ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

  @override
  void didUpdateWidget(LikeButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only pop on save, not on unsave — celebrating a removal is odd.
    if (widget.isSaved && !oldWidget.isSaved) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    // Both states are the same white; only the *fill* changes. This is the
    // brief's rule, and it is also the only version that works here — dimming
    // the unsaved heart to grey is how a hue-bearing app distinguishes the two,
    // but in a monochrome list a grey heart is indistinguishable from a
    // disabled one. Outline versus solid is a shape difference, which survives
    // both the palette and a glance.
    return Tooltip(
      message: widget.isSaved ? 'Remove from Liked Songs' : 'Save to Liked Songs',
      child: IconButton(
        onPressed: widget.enabled ? widget.onToggle : null,
        iconSize: widget.size,
        icon: ScaleTransition(
          scale: _scale,
          child: AurixIcon(
            widget.isSaved ? AurixGlyph.heartFilled : AurixGlyph.heart,
            color: widget.enabled ? palette.textPrimary : palette.textTertiary,
          ),
        ),
      ),
    );
  }
}
