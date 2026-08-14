// ignore_for_file: avoid_print — this is a command-line tool.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Generates the Android and iOS launcher icons for AURIX.
///
/// ```
/// dart run tool/generate_launcher_icons.dart
/// ```
///
/// ## Why this is a plain Dart script
///
/// The obvious approach — render the real `AurixLogo` widget through
/// `flutter test` and capture a `RepaintBoundary` — hangs on this toolchain.
/// It is also a heavyweight way to draw three shapes.
///
/// So the mark is rasterised here directly: no Flutter, no engine, no device.
/// It runs in about a second and is fully deterministic.
///
/// The cost is that the geometry below **mirrors** `_AurixMarkPainter` in
/// `lib/shared/widgets/brand/aurix_logo.dart` rather than sharing it. The
/// constants in [_Mark] are the single copy of those numbers on this side;
/// change the painter and change them together.
void main(List<String> args) {
  final root = Directory.current.path;

  // Android applies its own mask to legacy icons, so these are pre-rounded.
  const androidDensities = <String, int>{
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
  };

  // The set the default Flutter iOS project's Contents.json expects.
  const iosSizes = <String, int>{
    'Icon-App-20x20@1x': 20,
    'Icon-App-20x20@2x': 40,
    'Icon-App-20x20@3x': 60,
    'Icon-App-29x29@1x': 29,
    'Icon-App-29x29@2x': 58,
    'Icon-App-29x29@3x': 87,
    'Icon-App-40x40@1x': 40,
    'Icon-App-40x40@2x': 80,
    'Icon-App-40x40@3x': 120,
    'Icon-App-60x60@2x': 120,
    'Icon-App-60x60@3x': 180,
    'Icon-App-76x76@1x': 76,
    'Icon-App-76x76@2x': 152,
    'Icon-App-83.5x83.5@2x': 167,
    'Icon-App-1024x1024@1x': 1024,
  };

  var written = 0;

  for (final entry in androidDensities.entries) {
    final path = '$root/android/app/src/main/res/${entry.key}/ic_launcher.png';
    _write(path, _renderIcon(entry.value, rounded: true));
    written++;
  }

  for (final entry in iosSizes.entries) {
    // iOS masks its own corners, and rejects alpha in the 1024 marketing icon.
    final path =
        '$root/ios/Runner/Assets.xcassets/AppIcon.appiconset/${entry.key}.png';
    _write(path, _renderIcon(entry.value, rounded: false, opaque: true));
    written++;
  }

  // A 512px source, for store listings or a future flutter_launcher_icons run.
  _write('$root/assets/branding/app_icon_source.webp',
      _renderIcon(512, rounded: true));
  written++;

  print('Wrote $written launcher icons.');
}

void _write(String path, Uint8List png) {
  final file = File(path)..parent.createSync(recursive: true);
  file.writeAsBytesSync(png);
  print('  ${path.split(RegExp(r'[\\/]')).last.padRight(28)} '
      '${(png.length / 1024).toStringAsFixed(1)} KB');
}

// ---------------------------------------------------------------------------
// The mark
// ---------------------------------------------------------------------------

/// Geometry mirrored from `_AurixMarkPainter`. See the note in [main].
///
/// The mark is the letter A: two legs meeting at a rounded apex, plus a
/// crossbar that does not touch them. Every value here has a twin in
/// `aurix_logo.dart` and the two must be changed together — the icon is the
/// same drawing, and a launcher icon that disagrees with the in-app mark is
/// worse than either one alone.
abstract final class _Mark {
  /// Fraction of the icon the mark occupies. The remainder is the safe margin
  /// Android's adaptive mask crops into.
  static const double scale = 0.58;

  static const double apexY = 0.155;
  static const double baseY = 0.845;
  static const double halfWidth = 0.295;
  static const double strokeWidth = 0.115;
  static const double barY = 0.635;
  static const double barSpan = 0.52;
}

/// Pure white on near-black. The whole palette this icon needs.
const _ink = _Rgb(0xFF, 0xFF, 0xFF);
const _surfaceHigh = _Rgb(0x15, 0x15, 0x15);
const _surfaceLow = _Rgb(0x05, 0x05, 0x05);

/// Supersampling factor per axis. 4 means 16 samples per pixel, which is
/// enough to keep the apex clean at 48px without making the 1024px icon slow.
const int _ss = 4;

Uint8List _renderIcon(int size, {required bool rounded, bool opaque = false}) {
  final pixels = Uint8List(size * size * 4);

  final s = size.toDouble();
  final cornerR = rounded ? s * 0.22 : 0.0;

  // Mark geometry, in icon pixels.
  final edge = s * _Mark.scale;
  final cx = s / 2;
  final top = (s / 2) - (edge / 2);

  double gx(double f) => cx + (edge * f);
  double gy(double f) => top + (edge * f);

  // Half the stroke, which is also the round cap/join radius — a stroked
  // polyline is exactly the set of points within this distance of it, so
  // testing distance-to-segment gives round terminals for free. That is why
  // this rasteriser is a fraction of the size of the arc-based one it replaced.
  final half = edge * _Mark.strokeWidth / 2;

  final apex = _Pt(cx, gy(_Mark.apexY));
  final legL = _Pt(gx(-_Mark.halfWidth), gy(_Mark.baseY));
  final legR = _Pt(gx(_Mark.halfWidth), gy(_Mark.baseY));

  const legHalfAtBar =
      _Mark.halfWidth * ((_Mark.barY - _Mark.apexY) / (_Mark.baseY - _Mark.apexY));
  const barHalf = legHalfAtBar * _Mark.barSpan;
  final barL = _Pt(gx(-barHalf), gy(_Mark.barY));
  final barR = _Pt(gx(barHalf), gy(_Mark.barY));

  const step = 1.0 / _ss;
  const sampleWeight = 1.0 / (_ss * _ss);

  for (var py = 0; py < size; py++) {
    for (var px = 0; px < size; px++) {
      var bgCov = 0.0;
      var markCov = 0.0;

      for (var sy = 0; sy < _ss; sy++) {
        for (var sx = 0; sx < _ss; sx++) {
          final x = px + (sx + 0.5) * step;
          final y = py + (sy + 0.5) * step;

          if (_inRoundedRect(x, y, s, cornerR)) bgCov += sampleWeight;

          final onMark = _nearSegment(x, y, legL, apex, half) ||
              _nearSegment(x, y, apex, legR, half) ||
              _nearSegment(x, y, barL, barR, half);
          if (onMark) markCov += sampleWeight;
        }
      }

      // Composite: background, then mark.
      var r = 0.0, g = 0.0, b = 0.0, a = 0.0;

      if (bgCov > 0) {
        // Diagonal gradient, matching AurixLogoBadge.
        final d = ((px + py) / (2 * s)).clamp(0.0, 1.0);
        final bg = _lerp(_surfaceHigh, _surfaceLow, d);
        r = bg.r.toDouble();
        g = bg.g.toDouble();
        b = bg.b.toDouble();
        a = bgCov;
      }

      if (markCov > 0) {
        (r, g, b, a) = _over(_ink, markCov, r, g, b, a);
      }

      final i = ((py * size) + px) * 4;
      pixels[i] = r.round().clamp(0, 255);
      pixels[i + 1] = g.round().clamp(0, 255);
      pixels[i + 2] = b.round().clamp(0, 255);
      pixels[i + 3] = opaque ? 255 : (a * 255).round().clamp(0, 255);
    }
  }

  return _encodePng(size, size, pixels);
}

/// True when (x, y) lies within [radius] of the segment a–b.
///
/// Standard point-to-segment distance with the projection clamped to the
/// segment, which is what rounds the ends: past either endpoint the nearest
/// point *is* the endpoint, so the covered region is a disc there.
bool _nearSegment(double x, double y, _Pt a, _Pt b, double radius) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  final lengthSq = (dx * dx) + (dy * dy);

  var t = 0.0;
  if (lengthSq > 0) {
    t = (((x - a.x) * dx) + ((y - a.y) * dy)) / lengthSq;
    t = t.clamp(0.0, 1.0);
  }

  final nx = a.x + (t * dx);
  final ny = a.y + (t * dy);
  final ex = x - nx;
  final ey = y - ny;

  return ((ex * ex) + (ey * ey)) <= (radius * radius);
}

/// Source-over compositing of a coverage-weighted colour.
(double, double, double, double) _over(
  _Rgb src,
  double srcA,
  double dr,
  double dg,
  double db,
  double da,
) {
  final outA = srcA + da * (1 - srcA);
  if (outA <= 0) return (0, 0, 0, 0);
  final r = ((src.r * srcA) + (dr * da * (1 - srcA))) / outA;
  final g = ((src.g * srcA) + (dg * da * (1 - srcA))) / outA;
  final b = ((src.b * srcA) + (db * da * (1 - srcA))) / outA;
  return (r, g, b, outA);
}

bool _inRoundedRect(double x, double y, double size, double radius) {
  if (radius <= 0) return x >= 0 && y >= 0 && x <= size && y <= size;
  if (x < 0 || y < 0 || x > size || y > size) return false;

  final dx = math.max(radius - x, x - (size - radius));
  final dy = math.max(radius - y, y - (size - radius));
  if (dx <= 0 || dy <= 0) return true;
  return (dx * dx) + (dy * dy) <= radius * radius;
}

// The arc, cap-circle and point-in-triangle helpers that used to live here are
// gone with the ring-and-triangle mark. The letterform is three stroked
// segments, so `_nearSegment` above replaces all of them.

_Rgb _lerp(_Rgb a, _Rgb b, double t) {
  final u = t.clamp(0.0, 1.0);
  return _Rgb(
    (a.r + ((b.r - a.r) * u)).round(),
    (a.g + ((b.g - a.g) * u)).round(),
    (a.b + ((b.b - a.b) * u)).round(),
  );
}

class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}

class _Pt {
  const _Pt(this.x, this.y);
  final double x;
  final double y;
}

// ---------------------------------------------------------------------------
// PNG encoding
// ---------------------------------------------------------------------------

/// Minimal RGBA PNG writer: signature, IHDR, one IDAT, IEND.
///
/// Every scanline uses filter type 0 (none). Adaptive filtering would compress
/// better, but these files are a few KB either way and correctness matters
/// more than bytes here.
Uint8List _encodePng(int width, int height, Uint8List rgba) {
  final raw = BytesBuilder();
  for (var y = 0; y < height; y++) {
    raw.addByte(0);
    raw.add(Uint8List.sublistView(rgba, y * width * 4, (y + 1) * width * 4));
  }

  final compressed = ZLibCodec(level: 9).encode(raw.toBytes());

  final ihdr = BytesBuilder()
    ..add(_uint32(width))
    ..add(_uint32(height))
    ..addByte(8) // bit depth
    ..addByte(6) // colour type: RGBA
    ..addByte(0) // compression
    ..addByte(0) // filter
    ..addByte(0); // interlace

  final out = BytesBuilder()
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    ..add(_chunk('IHDR', ihdr.toBytes()))
    ..add(_chunk('IDAT', Uint8List.fromList(compressed)))
    ..add(_chunk('IEND', Uint8List(0)));

  return out.toBytes();
}

Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final body = BytesBuilder()
    ..add(typeBytes)
    ..add(data);
  final bodyBytes = body.toBytes();

  return (BytesBuilder()
        ..add(_uint32(data.length))
        ..add(bodyBytes)
        ..add(_uint32(_crc32(bodyBytes))))
      .toBytes();
}

Uint8List _uint32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value);

final List<int> _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final byte in bytes) {
    c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
