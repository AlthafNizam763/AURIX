import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/aurix_palette.dart';

/// The AURIX switch.
///
/// Material's `Switch` cannot express what this control has to say in a
/// monochrome system, so the whole thing is painted. The shape is deliberately
/// the familiar iOS capsule: a novel toggle silhouette costs recognition, and
/// recognition is the only job the shape has.
///
/// ## What "on" looks like without a colour to turn on
///
/// A hue-bearing switch says "on" by going green. With one accent and that
/// accent being white, the state change has to be carried by **inversion**:
///
///  * **Off** — a dark graphite track with a mid-grey thumb. Low contrast
///    against the settings list; the control recedes.
///  * **On** — the track fills with white and the thumb inverts to the page
///    colour, so the thumb becomes a *hole* punched in a lit track rather than
///    an object sitting on it.
///
/// That inversion is the whole design, and it is why the thumb is not simply
/// brightened: two white shapes on top of each other have no edge, and the
/// switch would read as a plain white capsule with no visible position.
class AurixSwitch extends StatefulWidget {
  const AurixSwitch({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final bool enabled;

  /// Announced by screen readers. The row's title when used in a settings list.
  final String? semanticLabel;

  static const double trackWidth = 52;
  static const double trackHeight = 30;

  /// Gap between the thumb and the track edge.
  static const double thumbInset = 3;

  /// The control's hit box, which is larger than its paint box so the switch
  /// still clears the 44px minimum tap target.
  static const Size tapTarget = Size(56, 44);

  @override
  State<AurixSwitch> createState() => _AurixSwitchState();
}

class _AurixSwitchState extends State<AurixSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// Long enough for the squash to read, short enough that the switch still
  /// feels like it responded to the tap rather than to a request.
  static const Duration _duration = Duration(milliseconds: 260);

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _duration,
      value: widget.value ? 1 : 0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduce motion turns the travel into a state change rather than removing
    // it: the thumb still moves, it just gets there immediately.
    _controller.duration =
        MediaQuery.disableAnimationsOf(context) ? Duration.zero : _duration;
  }

  @override
  void didUpdateWidget(AurixSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == oldWidget.value) return;
    if (widget.value) {
      _controller.forward();
    } else {
      _controller.reverse();
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

    return Semantics(
      label: widget.semanticLabel,
      toggled: widget.value,
      enabled: widget.enabled,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.enabled ? () => widget.onChanged(!widget.value) : null,
        child: SizedBox.fromSize(
          size: AurixSwitch.tapTarget,
          child: Center(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  size: const Size(
                    AurixSwitch.trackWidth,
                    AurixSwitch.trackHeight,
                  ),
                  painter: _AurixSwitchPainter(
                    t: Curves.easeOutCubic.transform(_controller.value),
                    // The squash is driven by the *raw* controller so it peaks
                    // at the halfway point of the travel rather than of the
                    // eased curve, which is where the eye expects the stretch.
                    travel: _controller.value,
                    enabled: widget.enabled,
                    accent: palette.accent,
                    trackOff: palette.surfaceHighest,
                    trackDisabled: palette.surface,
                    thumbOff: palette.textTertiary,
                    thumbOn: palette.ground,
                    hairline: palette.glassBorder,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AurixSwitchPainter extends CustomPainter {
  const _AurixSwitchPainter({
    required this.t,
    required this.travel,
    required this.enabled,
    required this.accent,
    required this.trackOff,
    required this.trackDisabled,
    required this.thumbOff,
    required this.thumbOn,
    required this.hairline,
  });

  /// Eased 0 → 1, driving every colour.
  final double t;

  /// Linear 0 → 1, driving the thumb's position and squash.
  final double travel;

  final bool enabled;
  final Color accent;
  final Color trackOff;
  final Color trackDisabled;
  final Color thumbOff;
  final Color thumbOn;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    final radius = size.height / 2;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    final lit = enabled ? t : 0.0;

    _paintTrack(canvas, rrect, lit);
    _paintBorder(canvas, rrect, lit);
    _paintThumb(canvas, size, lit);
  }

  void _paintTrack(Canvas canvas, RRect rrect, double lit) {
    // Off is the app's lightest dark surface, not a mid-grey: a grey track on a
    // near-black settings list reads as disabled rather than as off.
    canvas.drawRRect(
      rrect,
      Paint()..color = Color.lerp(
        enabled ? trackOff : trackDisabled,
        accent,
        lit,
      )!,
    );
  }

  /// Visible only while off. Once the track is lit there is nothing for a
  /// hairline to separate, and a border around a white capsule just softens its
  /// edge.
  void _paintBorder(Canvas canvas, RRect rrect, double lit) {
    if (lit > 0.98) return;

    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = hairline.withValues(alpha: hairline.a * (1 - lit)),
    );
  }

  void _paintThumb(Canvas canvas, Size size, double lit) {
    const inset = AurixSwitch.thumbInset;
    final r = (size.height / 2) - inset;

    // The thumb stretches into a capsule at the midpoint of its travel and
    // rounds back out at either end — the detail that makes an iOS switch feel
    // sprung rather than slid.
    final stretch = r * 0.34 * math.sin(travel * math.pi);
    final left = inset + r;
    final cx = left + ((size.width - inset - r - left) * travel);
    final cy = size.height / 2;

    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: Offset(cx, cy),
        width: (r * 2) + (stretch * 2),
        height: r * 2,
      ),
      Radius.circular(r),
    );

    // Off: a mid-grey object on a dark track. On: the page colour, so the thumb
    // reads as a hole punched through the lit track. See the class note.
    canvas.drawRRect(
      body,
      Paint()..color = Color.lerp(enabled ? thumbOff : trackOff, thumbOn, lit)!,
    );
  }

  @override
  bool shouldRepaint(_AurixSwitchPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.travel != travel ||
      oldDelegate.enabled != enabled ||
      oldDelegate.accent != accent ||
      oldDelegate.trackOff != trackOff ||
      oldDelegate.thumbOff != thumbOff ||
      oldDelegate.thumbOn != thumbOn ||
      oldDelegate.hairline != hairline;
}
