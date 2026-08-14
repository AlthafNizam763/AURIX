import 'dart:collection';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

import '../theme/aurix_palette.dart';
import 'app_logger.dart';

/// Tones sampled from a piece of artwork, converted to greyscale and
/// conditioned for use behind text.
///
/// ## Why artwork still gets sampled in a monochrome app
///
/// AURIX carries no hue, but a header that is identical for every album is a
/// header that tells you nothing. Sampling keeps the one property of the
/// artwork that survives the conversion — how *bright* it is — so a washed-out
/// ambient cover still gets a lighter wash than a black metal sleeve. The
/// gradient remains derived from the album; it just stops being coloured.
///
/// ## Luminance, not desaturation
///
/// The obvious implementation is to take the sampled colour and set its
/// saturation to zero. That is wrong here, and visibly so: HSL lightness is not
/// perceptual, so a saturated yellow and a saturated blue at the same nominal
/// lightness desaturate to *the same grey*. Two covers that look nothing alike
/// would produce identical headers, which defeats the only reason to sample.
///
/// [_luminanceOf] uses the Rec. 709 coefficients instead, which weight green
/// far above blue the way the eye does. That yellow lands near white and that
/// blue lands near black — the difference between the covers survives.
@immutable
class AlbumPalette {
  const AlbumPalette({
    required this.base,
    required this.accent,
    required this.isFallback,
  });

  /// Deep tone for the top of a header gradient. Already greyscale, already in
  /// the band where white text stays legible on top of it.
  final Color base;

  /// Brighter tone for glows, active states and the player background wash.
  final Color accent;

  /// True when nothing could be sampled and neutral defaults are in use.
  final bool isFallback;

  static const AlbumPalette fallback = AlbumPalette(
    base: Color(0xFF1F1F1F),
    accent: Color(0xFF2E2E2E),
    isFallback: true,
  );

  /// Builds a palette from a single normalised brightness in `0..1`. Used by
  /// surfaces that have no artwork to sample but still want a header that
  /// matches what a real cover would produce — Liked Songs, for instance.
  factory AlbumPalette.fromLuminance(double luminance, {bool isFallback = false}) {
    final l = luminance.clamp(0.0, 1.0);
    return AlbumPalette(
      base: _greyAt(_remap(l, 0.08, 0.20)),
      accent: _greyAt(_remap(l, 0.14, 0.30)),
      isFallback: isFallback,
    );
  }

  /// Gradient for an immersive header: the artwork's brightness fading into the
  /// app background so the content below joins seamlessly.
  ///
  /// Takes the theme rather than reading a global, because the tail of this
  /// gradient has to land exactly on the page colour — and in light mode that
  /// is off-white, not black. A gradient that ends on the wrong ground leaves a
  /// visible seam across the screen.
  List<Color> headerGradient(AurixPalette theme) {
    final top = _forTheme(base, theme);
    return <Color>[
      top,
      Color.lerp(top, theme.ground, 0.55)!,
      theme.ground,
    ];
  }

  /// Softer, taller gradient for the full-screen player.
  List<Color> playerGradient(AurixPalette theme) {
    final top = _forTheme(accent, theme);
    final mid = _forTheme(base, theme);
    return <Color>[
      Color.lerp(top, theme.ground, 0.25)!,
      Color.lerp(mid, theme.ground, 0.55)!,
      theme.ground,
    ];
  }

  /// Sampled tones are conditioned for a black page. On a white one the same
  /// grey would be a dark smear across the top of the screen, so the brightness
  /// is reflected into the light band — a dark cover still reads darker than a
  /// bright one, just as a deeper shade of off-white.
  static Color _forTheme(Color tone, AurixPalette theme) {
    if (theme.isDark) return tone;
    final l = _luminanceOf(tone);
    // The dark band spans roughly 0.05–0.35; reflect it into 0.80–0.94, which
    // is the range that reads as "tinted paper" rather than "grey box".
    return _greyAt(_remap(1.0 - l, 0.80, 0.94));
  }

  static Color _greyAt(double luminance) {
    final v = (luminance.clamp(0.0, 1.0) * 255).round();
    return Color.fromARGB(255, v, v, v);
  }

  static double _remap(double t, double low, double high) =>
      low + (high - low) * t.clamp(0.0, 1.0);

  /// Rec. 709 relative luminance. See the class note for why this rather than
  /// `HSLColor.withSaturation(0)`.
  static double _luminanceOf(Color color) =>
      (0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b).clamp(0.0, 1.0);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlbumPalette &&
          other.base == base &&
          other.accent == accent &&
          other.isFallback == isFallback;

  @override
  int get hashCode => Object.hash(base, accent, isFallback);
}

/// Extracts and caches [AlbumPalette]s from artwork URLs.
///
/// Palette generation decodes and quantises a bitmap, which is far too
/// expensive to redo every time a card scrolls back into view — results are
/// memoised in a bounded LRU, and in-flight requests are shared so a screen
/// that shows the same artwork twice only pays once.
class AlbumPaletteService {
  AlbumPaletteService({this.maxCacheEntries = 96});

  final int maxCacheEntries;

  final LinkedHashMap<String, AlbumPalette> _cache = LinkedHashMap();
  final Map<String, Future<AlbumPalette>> _inFlight = {};

  /// Returns a cached palette synchronously, or null if none has been computed.
  /// Lets a widget paint the right tone on first frame after a revisit instead
  /// of flashing the fallback.
  AlbumPalette? peek(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) return null;
    final hit = _cache.remove(imageUrl);
    if (hit != null) _cache[imageUrl] = hit;
    return hit;
  }

  Future<AlbumPalette> resolve(String? imageUrl) {
    if (imageUrl == null || imageUrl.isEmpty) {
      return Future.value(AlbumPalette.fallback);
    }
    final cached = peek(imageUrl);
    if (cached != null) return Future.value(cached);

    return _inFlight.putIfAbsent(imageUrl, () async {
      try {
        final generator = await PaletteGenerator.fromImageProvider(
          CachedNetworkImageProvider(imageUrl),
          // A small sample is plenty for a gradient and keeps the decode cheap.
          size: const Size(120, 120),
          maximumColorCount: 12,
        );
        final palette = _condition(generator);
        _store(imageUrl, palette);
        return palette;
      } on Object catch (error) {
        // A palette is decoration. If artwork fails to decode — offline, 404,
        // unsupported format — the screen must still render.
        AppLogger.warn('Palette extraction failed', scope: 'palette', error: error);
        _store(imageUrl, AlbumPalette.fallback);
        return AlbumPalette.fallback;
      } finally {
        _inFlight.remove(imageUrl);
      }
    });
  }

  void _store(String key, AlbumPalette palette) {
    _cache[key] = palette;
    while (_cache.length > maxCacheEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  void clear() {
    _cache.clear();
    _inFlight.clear();
  }

  AlbumPalette _condition(PaletteGenerator generator) {
    // Prefer the *dominant* colour now rather than the vibrant one. Vibrancy is
    // a hue property, and picking the most saturated swatch was how the old
    // coloured header found its brand moment. Once everything collapses to
    // brightness, the swatch that actually covers most of the sleeve is the one
    // that predicts how bright the cover looks.
    final source = generator.dominantColor?.color ??
        generator.darkMutedColor?.color ??
        generator.darkVibrantColor?.color ??
        generator.vibrantColor?.color;

    if (source == null) return AlbumPalette.fallback;

    return AlbumPalette.fromLuminance(AlbumPalette._luminanceOf(source));
  }
}
