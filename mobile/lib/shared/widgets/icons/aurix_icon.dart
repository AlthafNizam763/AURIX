import 'package:flutter/material.dart';

import '../../../core/theme/aurix_palette.dart';
import 'aurix_glyphs.dart';
import 'aurix_icon_geometry.dart';

/// Renders an [AurixGlyph] in the app's icon language.
///
/// A drop-in replacement for Material's `Icon`: it resolves its size and
/// colour from the ambient [IconTheme] the same way, so `IconButton`,
/// `ListTile` and `AppBar` keep styling it without any call site changing.
///
/// ## The language
///
/// Two rules, applied by the painter rather than drawn into each glyph — which
/// is what stops forty icons from each interpreting the style a little
/// differently:
///
///  1. **One geometry.** Every glyph is authored on [IconGrid]'s 24×24 canvas
///     with a 2.0 stroke and round terminals.
///  2. **Emphasis is a field, not a colour.** When [emphasis] is set — a
///     selected tab, an engaged shuffle — the glyph gains a soft filled disc
///     behind it in the accent at low alpha.
///
/// ## Why emphasis had to change shape
///
/// This used to be a chromatic fringe: two offset copies of the glyph in the
/// accent and the cold accent, plus a radial web at the hub. Both are
/// impossible here, and the fringe is impossible in an instructive way — an RGB
/// split needs two *hues* to separate. Rendered in a palette where the accent
/// and the fringe are both white, it stops being a fringe and becomes a blurry
/// glyph: it reads as a rendering fault, not as emphasis.
///
/// A backing disc has the property the fringe was reaching for and the fringe
/// never actually had: it distinguishes the engaged state by **area** rather
/// than by colour, so it survives being drawn in the same white as everything
/// around it. It is also what the platform's own transport controls do.
///
/// Small sizes suppress the decoration automatically — see [decorationFloor].
/// A disc behind an 18px glyph swallows it, and a disabled icon must not light.
class AurixIcon extends StatelessWidget {
  const AurixIcon(
    this.glyph, {
    this.size,
    this.color,
    this.emphasis = false,
    this.accent,
    this.semanticLabel,
    super.key,
  });

  final AurixGlyph glyph;

  /// Defaults to the ambient [IconTheme]'s size.
  final double? size;

  /// Defaults to the ambient [IconTheme]'s colour.
  final Color? color;

  /// Lights the emphasis treatment: a soft filled disc behind the glyph.
  final bool emphasis;

  /// Overrides the accent used by the emphasis treatment. The mini player
  /// passes the artwork-derived tone here so a lit icon agrees with the cover
  /// it is sitting on.
  final Color? accent;

  final String? semanticLabel;

  /// Below this the emphasis decoration is dropped and only the glyph is drawn.
  /// A backing disc on an 18px icon leaves no clear space around the glyph and
  /// reads as a smudge rather than as a state.
  static const double decorationFloor = 20;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final resolvedSize = size ?? iconTheme.size ?? 24;
    final resolvedColor =
        color ?? iconTheme.color ?? const Color(0xFFFFFFFF);

    // The ambient theme dims disabled icons through opacity. A glow behind a
    // dimmed glyph would undo exactly that signal, so emphasis is refused
    // whenever the icon is not at full strength.
    final opacity = iconTheme.opacity ?? 1;
    final palette = context.palette;
    final decorate =
        emphasis && resolvedSize >= decorationFloor && opacity > 0.99;

    Widget painted = CustomPaint(
      size: Size.square(resolvedSize),
      painter: AurixIconPainter(
        glyph: glyph,
        color: resolvedColor.withValues(alpha: resolvedColor.a * opacity),
        accent: accent ?? palette.accent,
        decorate: decorate,
      ),
    );

    if (decorate) {
      // Only emphasised icons are worth isolating: they repaint on selection
      // while their neighbours do not. A boundary around every list-row icon
      // would cost more than it saves.
      painted = RepaintBoundary(child: painted);
    }

    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: SizedBox.square(dimension: resolvedSize, child: painted),
    );
  }
}

/// Paints one glyph, plus the shared emphasis treatment.
class AurixIconPainter extends CustomPainter {
  const AurixIconPainter({
    required this.glyph,
    required this.color,
    required this.accent,
    required this.decorate,
  });

  final AurixGlyph glyph;
  final Color color;
  final Color accent;
  final bool decorate;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final scale = size.shortestSide / IconGrid.size;
    final shapes = glyph.build();

    canvas.save();
    canvas.scale(scale);

    if (decorate) _paintEmphasisField(canvas);

    _paintShapes(canvas, shapes, color);
    canvas.restore();
  }

  /// The soft disc behind an emphasised glyph.
  ///
  /// Two stops rather than a flat fill. A hard-edged circle at this alpha reads
  /// as a button the user has failed to notice is a button; feathering the last
  /// 30% of the radius makes it read as a state on the glyph instead. The
  /// radius sits just outside the 24×24 grid's drawn area, so no glyph in the
  /// set touches the falloff.
  void _paintEmphasisField(Canvas canvas) {
    const centre = IconGrid.centre;
    const radius = 11.5;

    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..isAntiAlias = true
        ..shader = RadialGradient(
          colors: <Color>[
            accent.withValues(alpha: 0.18),
            accent.withValues(alpha: 0.14),
            accent.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.7, 1],
        ).createShader(
          Rect.fromCircle(center: centre, radius: radius),
        ),
    );
  }

  void _paintShapes(
    Canvas canvas,
    List<IconShape> shapes,
    Color tint, {
    double dx = 0,
  }) {
    canvas.save();
    if (dx != 0) canvas.translate(dx, 0);

    for (final shape in shapes) {
      final paint = Paint()
        ..color = tint
        ..isAntiAlias = true;

      if (shape.filled) {
        paint.style = PaintingStyle.fill;
      } else {
        paint
          ..style = PaintingStyle.stroke
          ..strokeWidth = IconGrid.stroke * shape.weight
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
      }

      canvas.drawPath(shape.path, paint);
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(AurixIconPainter oldDelegate) =>
      oldDelegate.glyph != glyph ||
      oldDelegate.color != color ||
      oldDelegate.accent != accent ||
      oldDelegate.decorate != decorate;
}
