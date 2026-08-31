import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/effects/grain.dart';

/// The island's chrome: everything that is not the track.
///
/// All of it lives in [IslandFramePainter], because every layer either has to
/// escape the pill's edge or follow its animating corner radius — the lift, the
/// charcoal glass, the grain, the light sweep and the hairline. A painter can
/// bleed outside its bounds; a decorated box cannot.
///
/// This used to run a shared particle field inside the capsule as well. That is
/// gone: drifting motes are a texture the monochrome identity has no use for,
/// and at 46px tall they were competing with the one thing the island exists to
/// show — the track that is playing.
class IslandSkin extends StatelessWidget {
  const IslandSkin({
    required this.child,
    required this.radius,
    required this.glow,
    required this.surge,
    required this.sweep,
    required this.intensity,
    super.key,
  });

  final Widget child;

  /// Corner radius, which travels as the island expands.
  final double radius;

  /// 0–1 breathing pulse. Driven low while paused, so the island dims rather
  /// than disappearing.
  final double glow;

  /// 0–1 flash fired when the track changes.
  final double surge;

  /// 0–1 ambient clock for the light streak.
  final double sweep;

  /// Scales the ambience. Matches [glow] in intent but is tweened separately,
  /// because the particle field must not restart when the glow pulses.
  final double intensity;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return CustomPaint(
      painter: IslandFramePainter(
        radius: radius,
        glow: glow,
        surge: surge,
        sweep: sweep,
        accent: palette.accent,
        grain: palette.grain,
        hairline: palette.glassBorder,
        // A flat elevated surface now, where this used to be charcoal carrying
        // a cast of the colourway. The cast existed because the island floats
        // over artwork-derived backdrops and a neutral capsule on a *coloured*
        // screen reads as a cut-out hole. Those backdrops are greyscale as of
        // this design, so there is no hue left to disagree with — and the
        // capsule reads as an object again for exactly the same reason it used
        // to need help not to.
        charcoal: palette.surfaceElevated,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

/// Paints the island's capsule: bloom, glass, halftone, streak, hairline.
class IslandFramePainter extends CustomPainter {
  const IslandFramePainter({
    required this.radius,
    required this.glow,
    required this.surge,
    required this.sweep,
    required this.accent,
    required this.grain,
    required this.hairline,
    required this.charcoal,
  });

  final double radius;
  final double glow;
  final double surge;
  final double sweep;
  final Color accent;
  final Color grain;
  final Color hairline;
  final Color charcoal;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // One number drives every lit element, so a track change and a playing
    // pulse brighten the same things by the same amount instead of lighting
    // different parts of the island.
    final lit = (glow + surge).clamp(0.0, 1.0);

    _paintBloom(canvas, rrect, lit);
    _paintGlass(canvas, rect, rrect);

    canvas
      ..save()
      ..clipRRect(rrect);
    _paintGrain(canvas, size);
    _paintStreak(canvas, size);
    canvas.restore();

    _paintHairline(canvas, rect, rrect, lit);
  }

  /// The lift, painted *outside* the capsule: a dropped black shadow that makes
  /// the island float, and a very faint accent rim tight to the edge.
  ///
  /// The order matters and used to be the other way round. This was two
  /// coloured blooms, and in white they turned the island into the brightest
  /// object on the screen — a floating pill outshining the artwork behind it.
  /// A real shadow does the floating; the rim only has to be strong enough to
  /// keep the capsule's edge from dissolving into a dark backdrop.
  void _paintBloom(Canvas canvas, RRect rrect, double lit) {
    final paint = Paint()
      ..color = Colors.black.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 22);
    canvas.drawRRect(rrect.shift(const Offset(0, 6)).inflate(2), paint);

    paint
      ..color = accent.withValues(alpha: 0.05 + (0.07 * lit))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12 + (6 * lit));
    canvas.drawRRect(rrect.inflate(1), paint);
  }

  /// Dark glass. A near-black base, then two washes from opposite corners so
  /// the surface has a direction to it — flat fills are what make a glass panel
  /// look like a grey card.
  void _paintGlass(Canvas canvas, Rect rect, RRect rrect) {
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[charcoal, Colors.black],
        ).createShader(rect),
    );

    // One wash from the top left. The second, from the bottom right in the
    // counterweight hue, is gone — with both washes in the same white they
    // cancelled into an even lift, which is precisely the flat fill this is
    // meant to avoid. One directional highlight is what gives a surface a
    // light source; two opposing ones give it none.
    canvas.drawRRect(
      rrect,
      Paint()
        ..shader = RadialGradient(
          center: Alignment.topLeft,
          radius: 1.15,
          colors: <Color>[
            accent.withValues(alpha: 0.09 + (0.06 * glow)),
            accent.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
  }

  /// Grain, finer than the app's default spacing — the standard 5px cell on a
  /// 46px capsule is a visible speckle rather than a texture.
  void _paintGrain(Canvas canvas, Size size) {
    GrainPainter(
      spacing: 3,
      maxRadius: 0.6,
      color: grain,
      fade: GrainFade.topLeft,
    ).paint(canvas, size);
  }

  /// A single skewed light streak crossing the capsule.
  ///
  /// Derived from [sweep] rather than scheduled on a timer, so the whole island
  /// stays a pure function of one clock and parking that clock for "reduce
  /// motion" freezes every layer together.
  void _paintStreak(Canvas canvas, Size size) {
    // Alive for a tenth of the cycle. Any longer and a "glitch" becomes a
    // rotating shine, which is a different — and much cheaper-looking — effect.
    const window = 0.1;
    final local = sweep % 1.0;
    if (local > window) return;

    final progress = local / window;
    // In and out within the window, so the streak never pops off mid-flash.
    final fade = math.sin(progress * math.pi);

    final width = size.width * 0.14;
    final skew = size.height * 0.55;
    final x = (-size.width * 0.25) + (size.width * 1.5 * progress);

    final path = Path()
      ..moveTo(x, 0)
      ..lineTo(x + width, 0)
      ..lineTo(x + width - skew, size.height)
      ..lineTo(x - skew, size.height)
      ..close();

    canvas.drawPath(
      path,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            accent.withValues(alpha: 0),
            accent.withValues(alpha: 0.16 * fade),
            accent.withValues(alpha: 0),
          ],
        ).createShader(path.getBounds()),
    );
  }

  /// The edge.
  ///
  /// A single hairline that brightens with [lit], where this used to be a
  /// three-stop shader running accent → counterweight → cold accent. The shader
  /// existed to give a neon border a dimensional shift along its length; with
  /// one accent all three stops resolve to the same white and it degrades to a
  /// flat stroke that costs a gradient to draw.
  ///
  /// So it is a flat stroke, drawn as one — and the range is pulled well down.
  /// A near-opaque white outline is what makes a dark capsule look like a
  /// sticker rather than like glass.
  void _paintHairline(Canvas canvas, Rect rect, RRect rrect, double lit) {
    canvas.drawRRect(
      rrect.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..isAntiAlias = true
        ..color = Color.lerp(
          hairline,
          accent.withValues(alpha: 0.42),
          lit,
        )!,
    );
  }

  @override
  bool shouldRepaint(IslandFramePainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.glow != glow ||
      oldDelegate.surge != surge ||
      oldDelegate.sweep != sweep ||
      oldDelegate.accent != accent ||
      oldDelegate.grain != grain ||
      oldDelegate.hairline != hairline ||
      oldDelegate.charcoal != charcoal;
}
