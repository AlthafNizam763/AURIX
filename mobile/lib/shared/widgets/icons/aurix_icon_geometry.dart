import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The shared drawing vocabulary for every AURIX glyph.
///
/// Every icon is authored on a **24×24 grid** with a **2.0 stroke**, round
/// caps and round joins, and is scaled to the requested size at paint time.
/// That single constraint is what makes forty separately-drawn shapes read as
/// one family — far more than any amount of per-glyph styling would.
///
/// Glyphs are built from the helpers below rather than from raw `Path` calls,
/// so the terminals, corner radii and optical weights cannot drift between
/// icons drawn weeks apart.
abstract final class IconGrid {
  /// The authoring canvas. All coordinates below are in these units.
  static const double size = 24;

  static const Offset centre = Offset(12, 12);

  /// Base stroke width, in grid units.
  static const double stroke = 2;

  /// Optical inset from the canvas edge. Glyphs stay inside this so that
  /// neighbouring icons align on their *visual* mass rather than on their
  /// bounding boxes.
  static const double padding = 2.6;

  static const double minX = padding;
  static const double maxX = size - padding;
  static const double minY = padding;
  static const double maxY = size - padding;
}

/// One drawable element of a glyph.
///
/// Splitting stroke from fill matters: a filled play triangle and a stroked
/// home outline need different `Paint` configuration, and letting each glyph
/// declare which it wants keeps the painter itself free of special cases.
@immutable
class IconShape {
  const IconShape.stroke(this.path, {this.weight = 1})
    : filled = false;

  const IconShape.fill(this.path)
    : filled = true,
      weight = 1;

  final Path path;
  final bool filled;

  /// Multiplier on [IconGrid.stroke]. Used sparingly — a glyph that needs a
  /// noticeably different weight from its neighbours is usually badly drawn
  /// rather than genuinely special. The exceptions are hairline interior
  /// details (below 1) and single-dot terminals.
  final double weight;
}

/// A complete glyph: the shapes, in paint order.
typedef GlyphBuilder = List<IconShape> Function();

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

/// A straight segment.
Path iconLine(double x1, double y1, double x2, double y2) =>
    Path()
      ..moveTo(x1, y1)
      ..lineTo(x2, y2);

/// An open or closed polyline through [points].
Path iconPoly(List<Offset> points, {bool close = false}) {
  final path = Path()..moveTo(points.first.dx, points.first.dy);
  for (final point in points.skip(1)) {
    path.lineTo(point.dx, point.dy);
  }
  if (close) path.close();
  return path;
}

Path iconCircle(double cx, double cy, double r) =>
    Path()..addOval(Rect.fromCircle(center: Offset(cx, cy), radius: r));

Path iconRRect(
  double left,
  double top,
  double right,
  double bottom, {
  double radius = 2.4,
}) => Path()
  ..addRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTRB(left, top, right, bottom),
      Radius.circular(radius),
    ),
  );

/// An arc on the circle centred at ([cx], [cy]).
///
/// Angles are in degrees, measured clockwise from three o'clock, which is the
/// convention every glyph below uses — mixing radians and degrees between
/// glyphs is how arcs end up subtly inconsistent.
Path iconArc(
  double cx,
  double cy,
  double r,
  double startDegrees,
  double sweepDegrees,
) => Path()
  ..addArc(
    Rect.fromCircle(center: Offset(cx, cy), radius: r),
    startDegrees * math.pi / 180,
    sweepDegrees * math.pi / 180,
  );

/// A dot, drawn as a zero-length round-capped stroke.
///
/// Round caps mean this renders as a circle of exactly the stroke width, so
/// the three dots of a "more" glyph match the weight of every other stroke in
/// the set automatically.
Path iconDot(double cx, double cy) => Path()
  ..moveTo(cx, cy)
  ..lineTo(cx, cy);

/// A chevron pointing in [direction], centred on ([cx], [cy]).
Path iconChevron(double cx, double cy, double reach, AxisDirection direction) {
  return switch (direction) {
    AxisDirection.right => iconPoly([
      Offset(cx - reach * 0.5, cy - reach),
      Offset(cx + reach * 0.5, cy),
      Offset(cx - reach * 0.5, cy + reach),
    ]),
    AxisDirection.left => iconPoly([
      Offset(cx + reach * 0.5, cy - reach),
      Offset(cx - reach * 0.5, cy),
      Offset(cx + reach * 0.5, cy + reach),
    ]),
    AxisDirection.down => iconPoly([
      Offset(cx - reach, cy - reach * 0.5),
      Offset(cx, cy + reach * 0.5),
      Offset(cx + reach, cy - reach * 0.5),
    ]),
    AxisDirection.up => iconPoly([
      Offset(cx - reach, cy + reach * 0.5),
      Offset(cx, cy - reach * 0.5),
      Offset(cx + reach, cy + reach * 0.5),
    ]),
  };
}

/// An arrowhead at ([tipX], [tipY]) opening back toward [direction]'s origin.
Path iconArrowHead(
  double tipX,
  double tipY,
  double reach,
  AxisDirection direction,
) {
  return switch (direction) {
    AxisDirection.left => iconPoly([
      Offset(tipX + reach, tipY - reach),
      Offset(tipX, tipY),
      Offset(tipX + reach, tipY + reach),
    ]),
    AxisDirection.right => iconPoly([
      Offset(tipX - reach, tipY - reach),
      Offset(tipX, tipY),
      Offset(tipX - reach, tipY + reach),
    ]),
    AxisDirection.up => iconPoly([
      Offset(tipX - reach, tipY + reach),
      Offset(tipX, tipY),
      Offset(tipX + reach, tipY + reach),
    ]),
    AxisDirection.down => iconPoly([
      Offset(tipX - reach, tipY - reach),
      Offset(tipX, tipY),
      Offset(tipX + reach, tipY - reach),
    ]),
  };
}

/// A right-pointing triangle — the play mark, and the transport glyphs built
/// from it. Corners are eased by a round join at paint time rather than by
/// extra path points.
Path iconTriangle(double cx, double cy, double halfHeight) {
  final halfWidth = halfHeight * 0.88;
  return iconPoly([
    Offset(cx - halfWidth * 0.72, cy - halfHeight),
    Offset(cx + halfWidth, cy),
    Offset(cx - halfWidth * 0.72, cy + halfHeight),
  ], close: true);
}

/// A music note: filled head, stem, and an optional flag.
List<IconShape> iconNote({
  required double headX,
  required double headY,
  double headRadius = 2.5,
  double stemHeight = 8,
  bool flag = true,
}) {
  final stemX = headX + headRadius;
  return <IconShape>[
    IconShape.fill(iconCircle(headX, headY, headRadius)),
    IconShape.stroke(iconLine(stemX, headY, stemX, headY - stemHeight)),
    if (flag)
      IconShape.stroke(
        Path()
          ..moveTo(stemX, headY - stemHeight)
          ..quadraticBezierTo(
            stemX + 3.4,
            headY - stemHeight + 0.6,
            stemX + 3.2,
            headY - stemHeight + 3.4,
          ),
      ),
  ];
}
