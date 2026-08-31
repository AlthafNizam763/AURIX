import 'package:flutter/material.dart';

/// The AURIX palette — a strict monochrome system.
///
/// Every colour in the app resolves from here or from [AurixPalette], the
/// brightness-aware extension built on top of it. Widgets must never inline a
/// hex value.
///
/// ## Why monochrome is harder than it looks
///
/// A palette with no hue has only one axis left — luminance — so every
/// separation the UI needs has to be bought with it. That makes the *spacing*
/// of the ramp the whole design. The nine steps below are deliberately not
/// evenly distributed:
///
///  * The four darkest steps ([black] → [graphite]) sit within 13% luminance of
///    each other. That tight cluster is what lets a card sit on a surface on a
///    background and still read as three layers, without any of them looking
///    grey. Depth in AURIX comes from stacking these, never from a border.
///  * Then a deliberate gap to [gray] — nothing lives between #222222 and
///    #666666. That void is what makes text pop off a card instead of fading
///    into it.
///  * The three lightest steps carry all the text and the single accent.
///
/// ## The accent is white
///
/// With no hue to spend, the primary action colour is pure white on a black
/// field — the highest-contrast pairing available (21:1). This is why the play
/// button is a white disc with a black glyph: it is not a stylistic choice, it
/// is the only way to make one element outrank everything else on screen when
/// every element is grey.
abstract final class AppColors {
  // ---- The ramp ---------------------------------------------------------
  // The nine canonical AURIX steps. Everything below is an alias onto one of
  // these, so the whole identity can be re-tuned from this block alone.

  static const Color black = Color(0xFF000000);
  static const Color blackDeep = Color(0xFF050505);
  static const Color surfaceDark = Color(0xFF0D0D0D);
  static const Color surfaceElevatedTone = Color(0xFF151515);
  static const Color graphite = Color(0xFF222222);
  static const Color gray = Color(0xFF666666);
  static const Color grayLight = Color(0xFFA0A0A0);
  static const Color white = Color(0xFFFFFFFF);
  static const Color whiteSoft = Color(0xFFF5F5F5);

  // ---- Brand ------------------------------------------------------------

  /// The primary action colour: pure white.
  ///
  /// Play buttons, active tabs, focus rings, the filled state of any control
  /// that matters. Measures 21:1 against [textOnAccent] — the highest contrast
  /// the sRGB space allows, and the reason a single white disc reads as the one
  /// thing to press on a screen of greys.
  static const Color accent = white;

  /// Pressed state. A step *down* to soft white rather than to grey: at 19.8:1
  /// the black glyph on the play button stays far above AA for as long as a
  /// finger is on it, while the surface visibly dims.
  static const Color accentPressed = whiteSoft;

  /// White at 20%, for the tinted fill behind a selected chip or an active row.
  static const Color accentSoft = Color(0x33FFFFFF);

  /// Sits *on* [accent]. Pure black — 21:1.
  static const Color textOnAccent = black;

  // ---- Neutrals ---------------------------------------------------------
  // Pure neutral: red, green and blue channels are equal in every one of these.
  // The previous palette cooled its greys toward blue-violet to seat a warm red
  // and a cool violet; with no hue in the system that cast has nothing to
  // reconcile and would only read as a colour failure on a calibrated display.

  static const Color background = black;
  static const Color backgroundDeep = blackDeep;
  static const Color surface = surfaceDark;
  static const Color surfaceElevated = surfaceElevatedTone;
  static const Color surfaceHighest = graphite;

  static const Color scrim = Color(0xCC000000);

  /// Hairlines. Fine, low-alpha and white rather than a solid grey, so a
  /// divider picks up whatever surface it crosses instead of banding against it.
  static const Color divider = Color(0x14FFFFFF);
  static const Color dividerStrong = Color(0x24FFFFFF);
  static const Color overlayHover = Color(0x0FFFFFFF);
  static const Color overlayPressed = Color(0x1FFFFFFF);

  // ---- Glass ------------------------------------------------------------
  /// Fill and hairline for frosted panels. Both are deliberately low-alpha:
  /// glassmorphism reads as glass because of the *blur* behind it, and a panel
  /// opaque enough to be legible on its own is just a grey card.
  static const Color glassFill = Color(0x0FFFFFFF);
  static const Color glassFillStrong = Color(0x1AFFFFFF);
  static const Color glassBorder = Color(0x1FFFFFFF);

  /// Film grain. Barely visible by design — the texture should register as the
  /// noise floor of a photograph, never as a pattern. This is what keeps large
  /// flat black fields from banding on OLED panels.
  static const Color grain = Color(0x0AFFFFFF);

  // ---- Text -------------------------------------------------------------
  static const Color textPrimary = white;
  static const Color textSecondary = grayLight;
  static const Color textTertiary = gray;

  // ---- Status -----------------------------------------------------------
  // AURIX carries no hue, so status is separated by *luminance and icon*, not
  // colour. Every status surface in the app pairs one of these with a glyph and
  // a sentence — colour is never the only signal, which is the accessibility
  // requirement these would otherwise fail.
  //
  // If a destructive action ever needs a true red, change [error] here and
  // nothing else: it is referenced by name everywhere.

  /// Maximum attention. Pure white, always alongside an alert glyph.
  static const Color error = white;

  static const Color warning = whiteSoft;
  static const Color success = whiteSoft;
  static const Color info = grayLight;

  /// Neutral placeholder shown behind artwork that has not loaded yet.
  static const Color artworkPlaceholder = surfaceElevatedTone;

  // ---- Shimmer ----------------------------------------------------------
  // A two-step sweep across the tight dark cluster. The highlight is graphite
  // rather than anything brighter: a shimmer that outshines real content reads
  // as a defect, not as loading.
  static const Color shimmerBase = surfaceElevatedTone;
  static const Color shimmerHighlight = graphite;

  // ---- Brand surfaces ---------------------------------------------------

  /// The brand gradient: white falling through graphite into black.
  ///
  /// Used on the splash screen, the brand badge and empty-state artwork. The
  /// stops are weighted toward the dark end so the white reads as a highlight
  /// catching an edge rather than as a grey wash.
  static const List<Color> brandGradient = <Color>[white, graphite, black];

  /// Two-stop version for smaller surfaces where the third stop would compress
  /// into a muddy band.
  static const List<Color> accentGradient = <Color>[whiteSoft, graphite];

  /// Near-black backdrops behind the brand.
  static const Color brandSurfaceHigh = surfaceElevatedTone;
  static const Color brandSurfaceLow = blackDeep;

  /// Fallback gradient for content with no artwork to sample.
  static const List<Color> neutralHeaderGradient = <Color>[
    graphite,
    surfaceDark,
    black,
  ];

  /// White at a given alpha — the only glow AURIX has.
  static Color glow(double alpha) => white.withValues(alpha: alpha);

  /// Deterministic tone for a piece of content that has no artwork, so the same
  /// album always gets the same placeholder.
  ///
  /// The spread is narrow and entirely inside the dark cluster: these sit
  /// *behind* white text and a placeholder that competes with real artwork
  /// defeats the point. Variation here is only enough to stop a grid of
  /// artwork-less items reading as one flat block.
  static Color placeholderFor(String seed) {
    const palette = <Color>[
      Color(0xFF1A1A1A),
      Color(0xFF222222),
      Color(0xFF161616),
      Color(0xFF2A2A2A),
      Color(0xFF1E1E1E),
      Color(0xFF262626),
      Color(0xFF121212),
    ];
    if (seed.isEmpty) return palette.first;
    final hash = seed.codeUnits.fold<int>(
      7,
      (acc, unit) => (acc * 31 + unit) & 0x7FFFFFFF,
    );
    return palette[hash % palette.length];
  }
}
