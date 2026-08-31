import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Film grain.
///
/// ## Why a monochrome app needs texture more than a colourful one did
///
/// This replaced a comic halftone, and it is not only a style change. AURIX
/// puts large, flat, near-black fields behind almost everything, and an 8-bit
/// gradient across that much black *bands* — you get visible steps rather than
/// a smooth fade, and OLED panels make it worse by rendering the darkest steps
/// perfectly. A sparse, low-alpha scatter is the standard fix: it dithers the
/// gradient, breaking each step's edge into noise the eye reconstructs as a
/// continuous ramp.
///
/// So the texture is doing two jobs. It reads as the noise floor of a
/// photograph, which is what makes the surface feel like a print rather than a
/// screen fill — and it is load-bearing for the gradients.
///
/// ## Stratified, not random
///
/// The scatter is a *jittered grid*: the canvas is divided into [spacing]-sized
/// cells and one grain is placed at a random point inside each. Neither of the
/// obvious alternatives works —
///
///  * A regular grid is what the halftone did. At any density it reads as a
///    mesh, because the eye is extremely good at finding periodicity.
///  * Uniform random placement clumps. Real Poisson noise leaves visible voids
///    and clusters, which reads as dirt on the lens, not as grain.
///
/// Stratified sampling has neither failure: guaranteed even coverage, no
/// detectable period. It is also what film grain physically is — silver halide
/// crystals suspended at roughly even density.
///
/// The scatter is seeded and therefore identical every repaint, so this can sit
/// inside a `RepaintBoundary` and be rasterised exactly once.
class GrainPainter extends CustomPainter {
  const GrainPainter({
    this.spacing = 5,
    this.maxRadius = 0.9,
    this.color = AppColors.grain,
    this.fade = GrainFade.topLeft,
    this.opacity = 1,
    this.seed = 0x5EED,
  });

  /// Cell size of the jitter grid — one grain per cell, so smaller means
  /// denser. Around 4–7 reads as 35mm; past ~12 the grains become countable and
  /// it starts to look like the halftone this replaced.
  final double spacing;

  /// Radius of the largest grain. Sub-pixel on purpose: grain that resolves
  /// into discs is dust.
  final double maxRadius;

  final Color color;
  final GrainFade fade;

  /// Overall multiplier, for animating the texture in.
  final double opacity;

  /// Fixed so the scatter is stable across repaints. Vary it only to stop two
  /// adjacent grained surfaces sharing a visibly identical pattern.
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0.01 || size.isEmpty || spacing <= 0) return;

    final random = math.Random(seed);
    final paint = Paint()..style = PaintingStyle.fill;
    final diagonal =
        math.sqrt((size.width * size.width) + (size.height * size.height));

    for (var cellY = 0.0; cellY < size.height; cellY += spacing) {
      for (var cellX = 0.0; cellX < size.width; cellX += spacing) {
        // One grain per cell, placed anywhere within it.
        final point = Offset(
          cellX + (random.nextDouble() * spacing),
          cellY + (random.nextDouble() * spacing),
        );

        final t = _falloff(point, size, diagonal);
        if (t <= 0.02) continue;

        // Grain varies in both size and density in a real emulsion. Varying
        // only position produces a flat, uniform sheet that reads as a texture
        // *overlay* rather than as part of the image.
        final jitter = 0.35 + (random.nextDouble() * 0.65);

        paint.color = color.withValues(alpha: color.a * t * opacity * jitter);
        canvas.drawCircle(point, maxRadius * jitter, paint);
      }
    }
  }

  /// 1 at the fade's origin, 0 at the far edge.
  double _falloff(Offset point, Size size, double diagonal) {
    switch (fade) {
      case GrainFade.topLeft:
        return (1 - (point.distance / diagonal)).clamp(0.0, 1.0);
      case GrainFade.topRight:
        final d = (Offset(size.width, 0) - point).distance;
        return (1 - (d / diagonal)).clamp(0.0, 1.0);
      case GrainFade.top:
        return (1 - (point.dy / size.height)).clamp(0.0, 1.0);
      case GrainFade.bottom:
        return (point.dy / size.height).clamp(0.0, 1.0);
      case GrainFade.none:
        return 1;
    }
  }

  @override
  bool shouldRepaint(GrainPainter oldDelegate) =>
      oldDelegate.spacing != spacing ||
      oldDelegate.maxRadius != maxRadius ||
      oldDelegate.color != color ||
      oldDelegate.fade != fade ||
      oldDelegate.opacity != opacity ||
      oldDelegate.seed != seed;
}

enum GrainFade { topLeft, topRight, top, bottom, none }

/// Drops a [GrainPainter] behind [child].
///
/// `IgnorePointer` + `RepaintBoundary`: the texture is decorative, must never
/// eat a tap, and must not be re-rasterised when the content above it animates.
class GrainOverlay extends StatelessWidget {
  const GrainOverlay({
    required this.child,
    this.spacing = 5,
    this.maxRadius = 0.9,
    this.color = AppColors.grain,
    this.fade = GrainFade.topLeft,
    this.opacity = 1,
    this.seed = 0x5EED,
    super.key,
  });

  final Widget child;
  final double spacing;
  final double maxRadius;
  final Color color;
  final GrainFade fade;
  final double opacity;
  final int seed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: GrainPainter(
                  spacing: spacing,
                  maxRadius: maxRadius,
                  color: color,
                  fade: fade,
                  opacity: opacity,
                  seed: seed,
                ),
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
