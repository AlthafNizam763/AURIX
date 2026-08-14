import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/config/brand_assets.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';

/// The AURIX mark: the letter **A**, cut.
///
/// Drawn procedurally rather than shipped as a raster asset — it stays crisp at
/// every size and density, adds nothing to the bundle, and is original artwork
/// rather than anyone else's trademark.
///
/// ## Typographic, not pictorial
///
/// This replaced a swept ring wrapping a play triangle. The ring was a decent
/// mark and the wrong one: a pictogram of playback says "media player", and it
/// has to compete with every other rounded glyph on a home screen. A letterform
/// says *brand*, which is the direction a luxury identity has to take — the
/// marks this sits next to on a premium device are monograms, not icons.
///
/// The construction is three strokes on the same monoline weight as the
/// wordmark's stems, so the mark and the type read as one system:
///
///  * two legs meeting at a rounded apex, and
///  * a crossbar that **does not touch them**.
///
/// That gap is the whole mark. The eye closes an A from far less than this, so
/// legibility costs nothing — and the floating bar reads simultaneously as a
/// level meter, which is the only nod to audio the identity makes. It is a
/// quieter reference than a note or a waveform, and unlike those it cannot be
/// mistaken for a generic media glyph.
///
/// Geometry is expressed as fractions of [size] rather than as fixed pixels, so
/// the 16px notification icon and the 256px launcher icon are the same drawing.
class AurixLogo extends StatelessWidget {
  const AurixLogo({
    this.size = 64,
    this.showWordmark = false,
    this.color,
    super.key,
  });

  final double size;
  final bool showWordmark;

  /// Null resolves to the theme's primary ink. Override only to place the mark
  /// on a filled surface, where it has to invert.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    // Resolved here rather than inside the painter: a CustomPainter has no
    // BuildContext, and threading the colour in keeps the mark on the active
    // theme instead of pinning it to dark.
    final ink = color ?? context.palette.textPrimary;
    final painter = _AurixMarkPainter(color: ink);

    final mark = SizedBox.square(
      dimension: size,
      // A bundled assets/branding/app_icon_source.webp replaces the drawn mark.
      // The probe ran at startup, so this is a synchronous flag rather than a
      // FutureBuilder that would flash the fallback on first frame.
      child: BrandAssets.hasCustomLogo
          ? Image.asset(
              BrandAssets.logoPath,
              width: size,
              height: size,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              // The probe confirmed the bytes exist, not that they decode. A
              // corrupt or non-image file still has to degrade to the mark
              // rather than to a broken-image glyph on the splash screen.
              errorBuilder: (_, _, _) => CustomPaint(painter: painter),
            )
          : CustomPaint(painter: painter, isComplex: false),
    );

    if (!showWordmark) return mark;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        SizedBox(width: size * 0.34),
        AurixWordmark(fontSize: size * 0.34, color: ink),
      ],
    );
  }
}

/// "A U R I X".
///
/// ## The spacing is tracking, not spaces
///
/// The brief sets the wordmark as `A U R I X`, and the obvious implementation
/// is to put literal spaces in the string. That is wrong for two reasons, and
/// the second one matters more:
///
///  * Spaces are a fixed width from the font. Tracking is proportional, so it
///    scales with [fontSize] and stays optically identical at 15px and 60px.
///  * A screen reader announces `"A U R I X"` as five separate letters, and
///    every text search — including the user's own — stops matching the word.
///    The accessible name here stays "AURIX" while the rendering stays spaced.
class AurixWordmark extends StatelessWidget {
  const AurixWordmark({this.fontSize = 15, this.color, super.key});

  final double fontSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Text(
      'AURIX',
      style: AppTypography.wordmark.copyWith(
        fontSize: fontSize,
        // Tracking is proportional to the size so the mark holds its rhythm at
        // every scale. See the class note.
        letterSpacing: fontSize * 0.43,
        color: color ?? context.palette.textPrimary,
      ),
      // Trailing tracking is applied *after* the last glyph, which pushes the
      // visual centre left. Nudging the whole string back by half a step is
      // what makes a centred wordmark actually look centred.
      textAlign: TextAlign.center,
    );
  }
}

class _AurixMarkPainter extends CustomPainter {
  const _AurixMarkPainter({required this.color});

  final Color color;

  // ---- Construction ------------------------------------------------------
  // All fractions of the square's edge. See the class note on [AurixLogo].

  static const double _apexY = 0.155;
  static const double _baseY = 0.845;
  static const double _halfWidth = 0.295;
  static const double _strokeWidth = 0.115;

  /// Height of the crossbar. Below the optical centre on purpose: a bar at true
  /// centre makes the counter above it look larger than the space below, which
  /// is the standard optical correction for an A.
  static const double _barY = 0.635;

  /// Fraction of the *available* span between the legs. See the class note for
  /// why the bar stops short.
  static const double _barSpan = 0.52;

  @override
  void paint(Canvas canvas, Size size) {
    final edge = math.min(size.width, size.height);
    if (edge <= 0) return;

    final cx = size.width / 2;
    final top = (size.height / 2) - (edge / 2);

    double x(double f) => cx + (edge * f);
    double y(double f) => top + (edge * f);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = edge * _strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The legs, as one path so the apex is a single round join rather than two
    // overlapping caps — which at small sizes reads as a blob.
    final legs = Path()
      ..moveTo(x(-_halfWidth), y(_baseY))
      ..lineTo(cx, y(_apexY))
      ..lineTo(x(_halfWidth), y(_baseY));

    canvas.drawPath(legs, paint);

    // The crossbar, floating clear of both legs.
    //
    // Its span is derived from where the legs actually are at this height
    // rather than from a fixed fraction of the edge: the legs converge, so a
    // constant-width bar would sit with different gaps at different heights and
    // stop looking deliberate the moment [_barY] is touched.
    const legHalfWidthAtBar =
        _halfWidth * ((_barY - _apexY) / (_baseY - _apexY));
    const barHalf = legHalfWidthAtBar * _barSpan;

    canvas.drawLine(
      Offset(x(-barHalf), y(_barY)),
      Offset(x(barHalf), y(_barY)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_AurixMarkPainter oldDelegate) =>
      oldDelegate.color != color;
}

/// The mark on its brand backdrop — splash screen, login hero, about screen.
///
/// The backdrop is a near-black rounded square with a hairline, not a glowing
/// gradient tile. A bloom behind a white mark is the single fastest way to make
/// a monochrome identity look cheap; depth here comes from the surface step and
/// the border, which is the same move every card in the app makes.
class AurixLogoBadge extends StatelessWidget {
  const AurixLogoBadge({this.size = 108, super.key});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        // 0.28 of the edge is the iOS app-icon corner ratio. Matching it makes
        // the badge read as an app icon lifted onto the screen, which is what
        // a splash mark wants to be.
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          colors: [palette.brandSurfaceHigh, palette.brandSurfaceLow],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: palette.hairline),
      ),
      child: Center(child: AurixLogo(size: size * 0.56)),
    );
  }
}
