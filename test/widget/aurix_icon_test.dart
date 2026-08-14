import 'dart:ui' as ui;

import 'package:aurix/core/theme/aurix_palette.dart';
import 'package:aurix/shared/widgets/icons/aurix_glyphs.dart';
import 'package:aurix/shared/widgets/icons/aurix_icon.dart';
import 'package:aurix/shared/widgets/icons/aurix_icon_geometry.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// What a rasterised glyph actually put on the canvas.
class _Ink {
  const _Ink(this.lit, this.minX, this.minY, this.maxX, this.maxY, this.total);

  final int lit;
  final int minX;
  final int minY;
  final int maxX;
  final int maxY;
  final int total;

  double get coverage => lit / total;
  bool get isEmpty => lit == 0;
}

/// Paints [painter] at [box] onto a canvas twice that size, then reports where
/// the ink landed.
///
/// The oversized canvas is the point: a glyph whose coordinates escape the
/// 24×24 grid would be silently clipped by a tight canvas and look fine here,
/// while in the app it would collide with whatever sits beside it. Painting
/// with room to spill makes the overflow measurable.
Future<_Ink> _render(CustomPainter painter, {double box = 48}) async {
  final canvasSide = (box * 2).toInt();
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  painter.paint(canvas, Size.square(box));

  final image = await recorder.endRecording().toImage(canvasSide, canvasSide);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();

  final bytes = data!.buffer.asUint8List();
  var lit = 0;
  var minX = canvasSide, minY = canvasSide, maxX = -1, maxY = -1;

  for (var y = 0; y < canvasSide; y++) {
    for (var x = 0; x < canvasSide; x++) {
      // Ignore the faintest antialiasing so a stray 1/255 edge pixel does not
      // count as the glyph overflowing its box.
      if (bytes[((y * canvasSide) + x) * 4 + 3] < 8) continue;
      lit++;
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
  }

  return _Ink(lit, minX, minY, maxX, maxY, (box * box).toInt());
}

AurixIconPainter _painter(AurixGlyph glyph, {bool decorate = false}) =>
    AurixIconPainter(
      glyph: glyph,
      color: const Color(0xFFFFFFFF),
      accent: const Color(0xFFFFFFFF),
      decorate: decorate,
    );

void main() {
  group('every glyph', () {
    // Runs over the whole enum rather than a hand-listed sample, so a glyph
    // added later cannot skip the checks by not being mentioned here.
    for (final glyph in AurixGlyph.values) {
      test('${glyph.name}: draws something legible', () async {
        final ink = await _render(_painter(glyph));

        expect(ink.isEmpty, isFalse, reason: '${glyph.name} painted nothing');

        // A glyph covering almost the whole box is a solid blob — usually an
        // unclosed path that got filled, or a stroke weight typo.
        expect(
          ink.coverage,
          lessThan(0.62),
          reason: '${glyph.name} covers '
              '${(ink.coverage * 100).toStringAsFixed(0)}% of its box',
        );

        // And one covering almost nothing is a path that collapsed.
        expect(
          ink.coverage,
          greaterThan(0.012),
          reason: '${glyph.name} covers only '
              '${(ink.coverage * 100).toStringAsFixed(1)}% of its box',
        );
      });

      test('${glyph.name}: stays inside its box', () async {
        const box = 48.0;
        final ink = await _render(_painter(glyph), box: box);

        // One stroke width of tolerance: a shape drawn *on* the grid edge
        // legitimately puts half its stroke outside.
        const slack = IconGrid.stroke * (box / IconGrid.size);

        expect(
          ink.minX,
          greaterThanOrEqualTo(-slack),
          reason: '${glyph.name} overflows left',
        );
        expect(
          ink.minY,
          greaterThanOrEqualTo(-slack),
          reason: '${glyph.name} overflows top',
        );
        expect(
          ink.maxX,
          lessThanOrEqualTo(box + slack),
          reason: '${glyph.name} overflows right to ${ink.maxX}',
        );
        expect(
          ink.maxY,
          lessThanOrEqualTo(box + slack),
          reason: '${glyph.name} overflows bottom to ${ink.maxY}',
        );
      });

      test('${glyph.name}: renders at every size the app uses', () async {
        // 11 is the smallest in the codebase (the Connect chip); 64 is the
        // largest (empty-state artwork).
        for (final size in <double>[11, 18, 22, 24, 30, 48, 64]) {
          final ink = await _render(_painter(glyph), box: size);
          expect(ink.isEmpty, isFalse, reason: '${glyph.name} at ${size}px');
        }
      });
    }
  });

  group('emphasis treatment', () {
    test('adds ink rather than replacing it', () async {
      // The fringe and hub sit around the glyph; the glyph itself must still
      // be drawn on top at full strength.
      final plain = await _render(_painter(AurixGlyph.home));
      final lit = await _render(_painter(AurixGlyph.home, decorate: true));

      expect(lit.lit, greaterThan(plain.lit));
    });

    testWidgets('is suppressed below the decoration floor', (tester) async {
      // A fringe on an 18px icon reads as a rendering fault.
      await tester.pumpWidget(
        wrapForTest(
          const Row(
            children: [
              AurixIcon(AurixGlyph.home, size: 18, emphasis: true),
              AurixIcon(AurixGlyph.home, size: 24, emphasis: true),
            ],
          ),
        ),
      );

      final List<AurixIconPainter> painters = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((p) => p.painter)
          .whereType<AurixIconPainter>()
          .toList();

      expect(painters, hasLength(2));
      expect(painters.first.decorate, isFalse, reason: '18px must stay plain');
      expect(painters.last.decorate, isTrue, reason: '24px may be decorated');
    });

    testWidgets('is suppressed while the icon is dimmed', (tester) async {
      // IconTheme opacity is how the app greys a disabled control. A glow
      // behind a dimmed glyph would undo that signal.
      await tester.pumpWidget(
        wrapForTest(
          const IconTheme(
            data: IconThemeData(size: 24, opacity: 0.4),
            child: AurixIcon(AurixGlyph.play, emphasis: true),
          ),
        ),
      );

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(AurixIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as AurixIconPainter;

      expect(painter.decorate, isFalse);
    });
  });

  group('theme integration', () {
    testWidgets('inherits size and colour from IconTheme like Icon does',
        (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          const IconTheme(
            data: IconThemeData(size: 31, color: Color(0xFF00FF00)),
            child: AurixIcon(AurixGlyph.search),
          ),
        ),
      );

      final box = tester.widget<SizedBox>(
        find.descendant(
          of: find.byType(AurixIcon),
          matching: find.byType(SizedBox),
        ),
      );
      expect(box.width, 31);

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(AurixIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as AurixIconPainter;
      expect(painter.color, const Color(0xFF00FF00));
    });

    testWidgets('takes its emphasis accent from the active theme',
        (tester) async {
      // Light, specifically. The emphasis disc is drawn in the accent, and the
      // accent is the one token that swaps ends of the ramp between themes —
      // an icon that kept the dark accent would paint a white disc on a white
      // card.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light().copyWith(
            extensions: const <ThemeExtension<dynamic>>[AurixPalette.light],
          ),
          home: const Scaffold(
            body: AurixIcon(AurixGlyph.heart, size: 24, emphasis: true),
          ),
        ),
      );

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(AurixIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as AurixIconPainter;

      expect(painter.accent, AurixPalette.light.accent);
    });

    testWidgets('an explicit accent overrides the theme', (tester) async {
      // The mini player passes the artwork-derived colour so a lit icon agrees
      // with the cover behind it.
      await tester.pumpWidget(
        wrapForTest(
          const AurixIcon(
            AurixGlyph.play,
            size: 24,
            emphasis: true,
            accent: Color(0xFF00FFAA),
          ),
        ),
      );

      final painter = tester
          .widget<CustomPaint>(
            find.descendant(
              of: find.byType(AurixIcon),
              matching: find.byType(CustomPaint),
            ),
          )
          .painter! as AurixIconPainter;

      expect(painter.accent, const Color(0xFF00FFAA));
    });
  });

  group('the set is coherent', () {
    test('outline and filled hearts share a silhouette', () async {
      // They are built from one path on purpose; if that ever forks, the like
      // button will visibly change shape when it is tapped.
      final outline = await _render(_painter(AurixGlyph.heart));
      final filled = await _render(_painter(AurixGlyph.heartFilled));

      expect((outline.minX - filled.minX).abs(), lessThanOrEqualTo(3));
      expect((outline.maxX - filled.maxX).abs(), lessThanOrEqualTo(3));
      expect((outline.minY - filled.minY).abs(), lessThanOrEqualTo(3));
      expect((outline.maxY - filled.maxY).abs(), lessThanOrEqualTo(3));
      expect(
        filled.lit,
        greaterThan(outline.lit),
        reason: 'the filled heart should carry more ink than the outline',
      );
    });

    test('skipNext and skipPrevious mirror each other', () async {
      final next = await _render(_painter(AurixGlyph.skipNext));
      final previous = await _render(_painter(AurixGlyph.skipPrevious));

      // Same ink, mirrored — a hand-drawn pair drifts apart easily.
      expect((next.lit - previous.lit).abs(), lessThan(next.lit * 0.15));
    });

    test('shouldRepaint reacts to every visible field', () {
      const base = AurixIconPainter(
        glyph: AurixGlyph.home,
        color: Color(0xFFFFFFFF),
        accent: Color(0xFFFFFFFF),
        decorate: false,
      );

      expect(base.shouldRepaint(base), isFalse);
      expect(base.shouldRepaint(_painter(AurixGlyph.search)), isTrue);
      expect(
        base.shouldRepaint(_painter(AurixGlyph.home, decorate: true)),
        isTrue,
      );
    });
  });
}
