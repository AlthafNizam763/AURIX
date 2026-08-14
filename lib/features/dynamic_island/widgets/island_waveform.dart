import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The little equaliser inside the island.
///
/// Two things make this read as *music playing* rather than as a loading
/// indicator, and both are about how it stops:
///
///  * The bars never fall to nothing. At rest they hold a flat baseline, so a
///    paused island still shows an equaliser rather than an empty gap where a
///    control used to be.
///  * Pausing tweens the energy to zero rather than halting the ticker on the
///    spot. A waveform frozen mid-swing looks like a dropped frame; one that
///    settles looks like it stopped.
///
/// The bars also run at mutually non-integer rates, which is what keeps four
/// sine waves from marching in lockstep and turning into one wobbling block.
class IslandWaveform extends StatefulWidget {
  const IslandWaveform({
    required this.playing,
    required this.warm,
    required this.cold,
    this.bars = 4,
    this.width = 18,
    this.height = 15,
    super.key,
  });

  final bool playing;

  /// The warm end of the gradient across the bars — the colourway's accent.
  final Color warm;

  /// The cold end. Each bar sits somewhere between the two, so the equaliser
  /// carries the colourway rather than a single flat tint.
  ///
  /// Named for the *role* rather than for a palette token, because which token
  /// reads as "cold" differs by colourway — `pulse` in the default, and the
  /// caller is the one that knows.
  final Color cold;

  final int bars;
  final double width;
  final double height;

  @override
  State<IslandWaveform> createState() => _IslandWaveformState();
}

class _IslandWaveformState extends State<IslandWaveform>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// One full swing. Slow enough to read as rhythm, fast enough to look alive.
  static const Duration _period = Duration(milliseconds: 1100);

  /// How long the bars take to settle when playback stops.
  static const Duration _settle = Duration(milliseconds: 420);

  @override
  void initState() {
    super.initState();
    // Built unconditionally rather than lazily: a controller first touched in
    // `dispose()` builds a Ticker against a deactivated element. Same trap the
    // glitch and ambience widgets document.
    _controller = AnimationController(vsync: this, duration: _period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncTicker();
  }

  @override
  void didUpdateWidget(IslandWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncTicker();
  }

  void _syncTicker() {
    final still = MediaQuery.disableAnimationsOf(context) || !widget.playing;
    if (still) {
      if (_controller.isAnimating) _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);

    return RepaintBoundary(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(end: widget.playing && !reduced ? 1 : 0),
        duration: reduced ? Duration.zero : _settle,
        curve: Curves.easeOutCubic,
        builder: (context, energy, _) => AnimatedBuilder(
          animation: _controller,
          builder: (context, _) => CustomPaint(
            size: Size(widget.width, widget.height),
            painter: _WaveformPainter(
              t: _controller.value,
              energy: energy,
              bars: widget.bars,
              warm: widget.warm,
              cold: widget.cold,
            ),
          ),
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({
    required this.t,
    required this.energy,
    required this.bars,
    required this.warm,
    required this.cold,
  });

  /// 0–1, one full cycle.
  final double t;

  /// 0 parks every bar on the baseline; 1 is full swing.
  final double energy;

  final int bars;
  final Color warm;
  final Color cold;

  /// Bar height at rest, as a fraction of the full height.
  static const double _baseline = 0.26;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty || bars < 1) return;

    // Bars and gaps share a width, which keeps the group optically even at any
    // size without a second tunable.
    final unit = size.width / ((bars * 2) - 1);
    final angle = t * math.pi * 2;
    final paint = Paint()..style = PaintingStyle.fill;

    for (var i = 0; i < bars; i++) {
      final wave = 0.5 + (0.5 * math.sin((angle * (1 + (i * 0.37))) + (i * 1.9)));
      final factor = _baseline + ((1 - _baseline) * wave * energy);
      final height = size.height * factor;

      final tone = Color.lerp(
        warm,
        cold,
        bars == 1 ? 0.0 : i / (bars - 1),
      )!;

      paint.color = tone.withValues(alpha: 0.6 + (0.4 * factor));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          // Grown about the centre line rather than up from the floor: a
          // centred equaliser reads as a signal, a grounded one as a chart.
          Rect.fromLTWH(i * unit * 2, (size.height - height) / 2, unit, height),
          Radius.circular(unit / 2),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.energy != energy ||
      oldDelegate.bars != bars ||
      oldDelegate.warm != warm ||
      oldDelegate.cold != cold;
}
