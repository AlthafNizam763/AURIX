import 'package:flutter/material.dart';

/// Runs a short settle when [trigger] changes: the child rises a few pixels,
/// scales back to rest and fades up.
///
/// This is the AURIX equivalent of a transition flourish — used where a piece
/// of content is *replaced* rather than moved, which is where a plain crossfade
/// reads as a loading glitch: the splash mark landing, a track changing in the
/// full player, the island swapping metadata.
///
/// ## Why three tiny moves instead of one big one
///
/// Each component is individually almost subliminal — 8px of travel, 1.5% of
/// scale, a fade that starts over half-way up. Together they read as one object
/// settling into place under its own weight. Any one of them alone reads as an
/// effect: the fade on its own is a dissolve, the travel on its own is a slide,
/// the scale on its own is a pop. The brief asks for animation that feels calm
/// and intentional, and this is the shape that gets there — you should notice
/// that the screen responded, not that something animated.
///
/// It is a *settle*, not a loop. A permanently animating interface never lets
/// the raster cache stabilise, and reads as broken rather than as alive.
class SoftReveal extends StatefulWidget {
  const SoftReveal({
    required this.child,
    this.trigger,
    this.enabled = true,
    this.duration = const Duration(milliseconds: 520),
    this.maxOffset = 8.0,
    super.key,
  });

  final Widget child;

  /// Any value; a change restarts the settle.
  final Object? trigger;

  final bool enabled;
  final Duration duration;

  /// How far the child rises from, in logical pixels.
  final double maxOffset;

  @override
  State<SoftReveal> createState() => _SoftRevealState();
}

class _SoftRevealState extends State<SoftReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Constructed here unconditionally, and deliberately *not* as a lazy
    // `late final` initialiser. When [enabled] is false neither `initState` nor
    // `build` ever touches the controller, so `dispose()` became the first
    // access — which built a Ticker against an already-deactivated element and
    // threw "Looking up a deactivated widget's ancestor is unsafe". That hit
    // every reveal unmounted while "reduce motion" was on.
    //
    // An idle AnimationController costs nothing until something starts it.
    _controller = AnimationController(vsync: this, duration: widget.duration);
    if (widget.enabled) _controller.forward(from: 0);
  }

  @override
  void didUpdateWidget(SoftReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled && widget.trigger != oldWidget.trigger) {
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
    if (!widget.enabled) return widget.child;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        if (!_controller.isAnimating) return child!;

        final t = Curves.easeOutCubic.transform(_controller.value);

        // The fade is deliberately on a different curve to the movement, and
        // starts late. Fading in step with the travel makes the child appear to
        // arrive already faded-up, which loses the settle entirely.
        final fade = Curves.easeOut.transform(
          (_controller.value / 0.75).clamp(0.0, 1.0),
        );

        return Opacity(
          opacity: 0.55 + (0.45 * fade),
          child: Transform.translate(
            offset: Offset(0, widget.maxOffset * (1 - t)),
            child: Transform.scale(
              scale: 1 + (0.015 * (1 - t)),
              child: child,
            ),
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// Page transition: a soft rise as the incoming route settles.
///
/// Deliberately paired with — not a replacement for — the platform's own
/// transition. It layers a small vertical settle over whatever
/// `pageTransitionsTheme` already does, so navigation still feels native on
/// both platforms while picking up the same settle the rest of the app uses.
Widget revealTransition(
  BuildContext context,
  Animation<double> animation,
  Widget child, {
  bool enabled = true,
  double distance = 12,
}) {
  if (!enabled) return child;

  return AnimatedBuilder(
    animation: animation,
    builder: (context, inner) {
      final t = Curves.easeOutCubic.transform(animation.value);
      return Transform.translate(
        offset: Offset(0, distance * (1 - t)),
        child: Opacity(opacity: t.clamp(0.0, 1.0), child: inner),
      );
    },
    child: child,
  );
}
