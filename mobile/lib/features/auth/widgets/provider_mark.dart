import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/aurix_palette.dart';
import '../../../data/models/auth_method.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

/// The mark on a sign-in option.
///
/// ## Drawn, not shipped
///
/// Every mark here is constructed from arcs and Béziers on a unit square, the
/// same way [AurixLogo] is, and for the same three reasons: it stays crisp at
/// every density, it adds nothing to the bundle, and it needs no asset
/// pipeline. Geometry is expressed as fractions of [size], so the 18px mark in
/// a settings row and the 28px one on the login screen are one drawing.
///
/// ## What these are, honestly
///
/// They are recognisable constructions, not the official artwork. Google,
/// Apple, Meta and GitHub all publish brand guidelines that require their own
/// files, unmodified, with specified clear space — and a deployment shipping
/// this to a store should follow them. Doing that is a change to exactly one
/// place: give [ProviderMark] a `switch` that returns an `Image.asset` for the
/// providers whose artwork has been added, and leave the rest drawn. Nothing
/// else in the sign-in flow knows or cares what this widget renders.
///
/// The constructions are used until then because the alternative — a grey
/// placeholder box, or four identical circles with letters in them — makes the
/// login screen look unfinished, and because a wrong-coloured official asset
/// would be a worse guideline violation than an obvious approximation.
///
/// ## Colour
///
/// Apple and GitHub are monochrome by design and take the ambient text colour,
/// which is what makes them work in both themes without a second asset. Google
/// and Facebook are defined *by* their colour and keep it.
class ProviderMark extends StatelessWidget {
  const ProviderMark(this.method, {this.size = 22, super.key});

  final AuthMethod method;
  final double size;

  @override
  Widget build(BuildContext context) {
    // Phone is not a brand. It belongs to the app's own icon language, drawn
    // in the same monoline as every other glyph, and would look imported
    // beside itself if it were redrawn here.
    if (method == AuthMethod.phone) {
      return AurixIcon(
        AurixGlyph.phone,
        size: size,
        color: context.palette.textPrimary,
      );
    }
    if (method == AuthMethod.password) {
      return AurixIcon(
        AurixGlyph.mail,
        size: size,
        color: context.palette.textPrimary,
      );
    }

    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _ProviderMarkPainter(
          method: method,
          monochrome: context.palette.textPrimary,
        ),
      ),
    );
  }
}

class _ProviderMarkPainter extends CustomPainter {
  const _ProviderMarkPainter({required this.method, required this.monochrome});

  final AuthMethod method;

  /// Used by the marks that are defined as a silhouette rather than by a hue.
  final Color monochrome;

  @override
  void paint(Canvas canvas, Size size) {
    // Every construction below is authored on a 1x1 square and scaled here, so
    // no mark carries pixel measurements of its own.
    canvas.save();
    canvas.scale(size.width, size.height);

    switch (method) {
      case AuthMethod.google:
        _google(canvas);
      case AuthMethod.apple:
        _apple(canvas, monochrome);
      case AuthMethod.facebook:
        _facebook(canvas);
      case AuthMethod.github:
        _github(canvas, monochrome);
      case AuthMethod.password || AuthMethod.phone:
        break;
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(_ProviderMarkPainter old) =>
      old.method != method || old.monochrome != monochrome;
}

// ---------------------------------------------------------------------------
// Google
// ---------------------------------------------------------------------------

/// The four-colour G.
///
/// Genuinely arcs: the mark is one ring of constant weight, cut into four
/// coloured segments with an opening at the lower right, plus a bar entering
/// that opening. Constructing it is therefore closer to tracing than to
/// approximating — the only judgement is where each colour hands over.
void _google(Canvas canvas) {
  const centre = Offset(0.5, 0.5);
  const radius = 0.335;
  const weight = 0.20;

  final ring = Rect.fromCircle(center: centre, radius: radius);
  final stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = weight
    // Butt caps, so neighbouring segments meet flush instead of overlapping
    // into a darker seam where two colours cross.
    ..strokeCap = StrokeCap.butt;

  // Flutter's angles: 0 is 3 o'clock and positive sweeps clockwise, so 90 is
  // the bottom of the ring and 270 is the top.
  void segment(Color colour, double startDegrees, double sweepDegrees) {
    canvas.drawArc(
      ring,
      startDegrees * math.pi / 180,
      sweepDegrees * math.pi / 180,
      false,
      stroke..color = colour,
    );
  }

  segment(const Color(0xFF34A853), 72, 88); //  green  — bottom
  segment(const Color(0xFFFBBC05), 160, 65); // yellow — left
  segment(const Color(0xFFEA4335), 225, 90); // red    — top
  segment(const Color(0xFF4285F4), 315, 45); // blue   — upper right

  // The bar. It closes the opening the arcs left at 0-72 degrees, which is
  // what turns a ring into a G rather than a broken circle.
  canvas.drawRect(
    const Rect.fromLTRB(0.50, 0.40, 0.50 + radius + weight / 2, 0.60),
    Paint()..color = const Color(0xFF4285F4),
  );
}

// ---------------------------------------------------------------------------
// Apple
// ---------------------------------------------------------------------------

/// The apple: two lobes meeting in a shallow valley, a leaf, and the bite.
///
/// Monochrome, which is not a simplification — Apple's own guidance is that the
/// mark is used in solid black or solid white. Taking the ambient text colour
/// therefore gets both themes right with one drawing.
void _apple(Canvas canvas, Color colour) {
  final body = Path()
    // Start in the valley between the two lobes, at the top centre.
    ..moveTo(0.50, 0.335)
    // Left lobe, down the left side and round the bottom.
    ..cubicTo(0.40, 0.245, 0.20, 0.275, 0.155, 0.470)
    ..cubicTo(0.105, 0.690, 0.265, 0.955, 0.395, 0.955)
    ..cubicTo(0.450, 0.955, 0.470, 0.905, 0.500, 0.905)
    // Right lobe, mirrored.
    ..cubicTo(0.530, 0.905, 0.550, 0.955, 0.605, 0.955)
    ..cubicTo(0.735, 0.955, 0.895, 0.690, 0.845, 0.470)
    ..cubicTo(0.800, 0.275, 0.600, 0.245, 0.500, 0.335)
    ..close();

  final leaf = Path()
    ..moveTo(0.520, 0.315)
    ..cubicTo(0.505, 0.195, 0.575, 0.085, 0.700, 0.045)
    ..cubicTo(0.725, 0.170, 0.655, 0.280, 0.520, 0.315)
    ..close();

  // The bite, taken out rather than painted over, so the mark composites
  // correctly on any background — painting the background colour into the
  // notch would leave a visible rectangle over a gradient.
  final bite = Path()
    ..addOval(Rect.fromCircle(center: const Offset(0.99, 0.50), radius: 0.175));

  final paint = Paint()..color = colour;
  canvas.drawPath(Path.combine(PathOperation.difference, body, bite), paint);
  canvas.drawPath(leaf, paint);
}

// ---------------------------------------------------------------------------
// Facebook
// ---------------------------------------------------------------------------

/// The white **f** knocked out of the blue disc.
///
/// Knocked out rather than drawn on top, for the same reason Apple's bite is
/// subtracted: the letter is a hole in the disc, so nothing has to guess what
/// colour is behind the mark.
void _facebook(Canvas canvas) {
  final disc = Path()
    ..addOval(Rect.fromCircle(center: const Offset(0.5, 0.5), radius: 0.5));

  // Traced anticlockwise from the top of the ascender: down the left of the
  // hook, out to the crossbar, down the stem, and back up the right.
  final letter = Path()
    ..moveTo(0.700, 0.255)
    ..lineTo(0.610, 0.255)
    ..cubicTo(0.495, 0.255, 0.455, 0.325, 0.455, 0.430)
    ..lineTo(0.455, 0.500)
    ..lineTo(0.345, 0.500)
    ..lineTo(0.345, 0.625)
    ..lineTo(0.455, 0.625)
    ..lineTo(0.455, 0.960)
    ..lineTo(0.600, 0.960)
    ..lineTo(0.600, 0.625)
    ..lineTo(0.700, 0.625)
    ..lineTo(0.722, 0.500)
    ..lineTo(0.600, 0.500)
    ..lineTo(0.600, 0.445)
    ..cubicTo(0.600, 0.400, 0.622, 0.385, 0.665, 0.385)
    ..lineTo(0.700, 0.385)
    ..close();

  canvas.drawPath(
    Path.combine(PathOperation.difference, disc, letter),
    Paint()..color = const Color(0xFF1877F2),
  );
}

// ---------------------------------------------------------------------------
// GitHub
// ---------------------------------------------------------------------------

/// The cat, as a silhouette: a rounded head with two ears and two legs.
///
/// The most approximate of the four, and the one that survives approximation
/// best — at 22 logical pixels the official mark reads as a dark blob with ears
/// too, and the ears are what identify it.
void _github(Canvas canvas, Color colour) {
  final paint = Paint()..color = colour;

  final silhouette = Path()
    // Left ear, swept up from the shoulder.
    ..moveTo(0.175, 0.300)
    ..cubicTo(0.150, 0.185, 0.190, 0.090, 0.235, 0.055)
    ..cubicTo(0.300, 0.090, 0.335, 0.140, 0.350, 0.180)
    // Across the crown to the right ear.
    ..cubicTo(0.445, 0.145, 0.555, 0.145, 0.650, 0.180)
    ..cubicTo(0.665, 0.140, 0.700, 0.090, 0.765, 0.055)
    ..cubicTo(0.810, 0.090, 0.850, 0.185, 0.825, 0.300)
    // Down the right side of the head and round the bottom.
    ..cubicTo(0.900, 0.390, 0.930, 0.500, 0.930, 0.590)
    ..cubicTo(0.930, 0.760, 0.835, 0.870, 0.690, 0.910)
    ..lineTo(0.690, 0.985)
    ..lineTo(0.560, 0.985)
    ..lineTo(0.560, 0.905)
    ..lineTo(0.440, 0.905)
    ..lineTo(0.440, 0.985)
    ..lineTo(0.310, 0.985)
    ..lineTo(0.310, 0.910)
    ..cubicTo(0.165, 0.870, 0.070, 0.760, 0.070, 0.590)
    ..cubicTo(0.070, 0.500, 0.100, 0.390, 0.175, 0.300)
    ..close();

  canvas.drawPath(silhouette, paint);
}
