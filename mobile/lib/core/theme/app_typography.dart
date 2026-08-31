import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'theme_config.dart';

/// Typographic scale for AURIX, set in Manrope.
///
/// ## Why a bundled face
///
/// AURIX has no colour to carry its identity, so the typeface has to do work
/// that a logo and an accent hue would normally share. Manrope is geometric
/// with a high x-height and near-circular bowls — it holds its shape at the
/// wide tracking the wordmark needs, which is exactly where a default UI face
/// falls apart. One variable file covers 200–800, so the whole scale costs
/// 165KB, renders identically on every platform, and never touches the network.
///
/// ## Weights come from `fontVariations`, not from `fontWeight`
///
/// With a variable font, `fontWeight` alone only picks a weight if the file is
/// registered once per weight in the manifest — which loads the same 165KB
/// under seven names. Instead the file is registered once and each style names
/// its weight on the `wght` axis. Every style below sets *both*: the axis value
/// is what actually renders, and the matching `fontWeight` keeps
/// `TextStyle.lerp`, `apply()` and the accessibility bold-text setting behaving
/// sensibly.
///
/// Each `fontVariations` list is written out longhand rather than built by a
/// helper, because these have to stay `const`. A `static const TextStyle` is
/// what lets roughly two dozen call sites across the app say
/// `const Text(..., style: AppTypography.bodySmall)` — turning this scale into
/// getters compiles, and then silently costs a `TextStyle` allocation on every
/// one of those builds.
///
/// Manrope's axis stops at 800. The scale was previously set in w900, so the
/// display register buys its authority back with tighter tracking instead —
/// see [displayLarge].
///
/// ## The hierarchy
///
/// Four registers, and screens are expected to pick one of each rather than
/// mixing sizes freely:
///
///  * **Wordmark** — [wordmark] only. Wide-tracked caps, one per surface.
///  * **Display** — w800, tight negative tracking. One per screen, maximum.
///  * **Headline / Title** — w700–w600. Section headers and item titles.
///  * **Body / Label** — w400–w600. Everything else.
abstract final class AppTypography {
  static const String fontFamily = 'Manrope';

  // ---- Wordmark ---------------------------------------------------------

  /// "A U R I X".
  ///
  /// The tracking is the brand. Manrope's caps are close to monoline and nearly
  /// circular, so at this spacing the five letters read as five separate marks
  /// on a field rather than as a word — which is the whole idea. Below roughly
  /// +4.0 it collapses back into ordinary bold caps and stops being a logo.
  static const TextStyle wordmark = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.1,
    fontWeight: FontWeight.w800,
    fontVariations: <FontVariation>[FontVariation('wght', 800)],
    letterSpacing: 6.5,
    color: AppColors.textPrimary,
  );

  // ---- Display ----------------------------------------------------------

  /// Display — reserved for hero headers (artist name, playlist title).
  ///
  /// Tracking is aggressive because the weight cannot go further: at w800 and
  /// 44px, pulling the letters together is what separates a poster headline
  /// from a large paragraph. It is only safe at this size — the same value on
  /// body copy would be unreadable.
  static const TextStyle displayLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 44,
    height: 1.02,
    fontWeight: FontWeight.w800,
    fontVariations: <FontVariation>[FontVariation('wght', 800)],
    letterSpacing: -1.8,
    color: AppColors.textPrimary,
  );

  static const TextStyle displayMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 34,
    height: 1.06,
    fontWeight: FontWeight.w800,
    fontVariations: <FontVariation>[FontVariation('wght', 800)],
    letterSpacing: -1.25,
    color: AppColors.textPrimary,
  );

  static const TextStyle displaySmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    height: 1.12,
    fontWeight: FontWeight.w800,
    fontVariations: <FontVariation>[FontVariation('wght', 780)],
    letterSpacing: -0.9,
    color: AppColors.textPrimary,
  );

  // ---- Headline ---------------------------------------------------------

  /// Section headers ("Made for you").
  static const TextStyle headlineLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    height: 1.2,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 720)],
    letterSpacing: -0.5,
    color: AppColors.textPrimary,
  );

  static const TextStyle headlineMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 20,
    height: 1.22,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 700)],
    letterSpacing: -0.35,
    color: AppColors.textPrimary,
  );

  static const TextStyle headlineSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    height: 1.26,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 700)],
    letterSpacing: -0.2,
    color: AppColors.textPrimary,
  );

  // ---- Title ------------------------------------------------------------

  /// Card titles and track names — the "large bold" register the song title
  /// uses everywhere it appears in a list.
  static const TextStyle titleMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation('wght', 640)],
    letterSpacing: -0.1,
    color: AppColors.textPrimary,
  );

  static const TextStyle titleSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13.5,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation('wght', 620)],
    color: AppColors.textPrimary,
  );

  // ---- Body -------------------------------------------------------------

  static const TextStyle bodyLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.45,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation('wght', 420)],
    color: AppColors.textPrimary,
  );

  /// Artist names and descriptions — the medium register that sits under a
  /// title.
  static const TextStyle bodyMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13.5,
    height: 1.42,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation('wght', 450)],
    color: AppColors.textSecondary,
  );

  /// Metadata — small and muted.
  static const TextStyle bodySmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    height: 1.36,
    fontWeight: FontWeight.w400,
    fontVariations: <FontVariation>[FontVariation('wght', 450)],
    color: AppColors.textSecondary,
  );

  // ---- Label ------------------------------------------------------------

  static const TextStyle labelLarge = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 700)],
    letterSpacing: 0.1,
    color: AppColors.textPrimary,
  );

  static const TextStyle labelMedium = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12,
    height: 1.2,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation('wght', 620)],
    letterSpacing: 0.2,
    color: AppColors.textSecondary,
  );

  static const TextStyle labelSmall = TextStyle(
    fontFamily: fontFamily,
    fontSize: 10.5,
    height: 1.16,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 700)],
    letterSpacing: 0.8,
    color: AppColors.textTertiary,
  );

  /// Small-caps overline above section headers. Tracking is *positive* here —
  /// caps set tight are unreadable.
  static const TextStyle overline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w700,
    fontVariations: <FontVariation>[FontVariation('wght', 700)],
    letterSpacing: 1.8,
    color: AppColors.textTertiary,
  );

  /// Monospaced figures so timers do not jitter as the digits change.
  static const TextStyle timecode = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11.5,
    height: 1.1,
    fontWeight: FontWeight.w600,
    fontVariations: <FontVariation>[FontVariation('wght', 600)],
    letterSpacing: 0.2,
    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    color: AppColors.textSecondary,
  );

  static TextTheme get textTheme => const TextTheme(
    displayLarge: displayLarge,
    displayMedium: displayMedium,
    displaySmall: displaySmall,
    headlineLarge: headlineLarge,
    headlineMedium: headlineMedium,
    headlineSmall: headlineSmall,
    titleLarge: headlineSmall,
    titleMedium: titleMedium,
    titleSmall: titleSmall,
    bodyLarge: bodyLarge,
    bodyMedium: bodyMedium,
    bodySmall: bodySmall,
    labelLarge: labelLarge,
    labelMedium: labelMedium,
    labelSmall: labelSmall,
  );

  // -------------------------------------------------------------------------
  // Configured typography
  // -------------------------------------------------------------------------

  /// Re-cuts the scale in an administrator's chosen face, size and weight.
  ///
  /// ## What is configurable, and what is not
  ///
  /// The family, one scale multiplier, one tracking delta and four weight steps.
  /// The *relative* sizes are not, and that is the constraint worth defending:
  /// the ratios between display, headline, title and body are the hierarchy, and
  /// an operator handed fifteen independent point sizes will eventually flatten
  /// them into a wall of same-sized text. A multiplier cannot do that — it
  /// scales the whole system and keeps its proportions.
  ///
  /// ## Why every style sets both `fontWeight` and `fontVariations`
  ///
  /// Manrope is a variable font registered once. `fontWeight` alone only selects
  /// a weight when the file is registered per weight in the manifest, so the
  /// `wght` axis is what actually renders — see the note at the top of this
  /// file. The matching `fontWeight` is still set so `TextStyle.lerp`,
  /// `apply()` and the accessibility bold-text setting keep behaving sensibly.
  ///
  /// A *non*-variable uploaded font ignores `fontVariations` and honours
  /// `fontWeight`, which is why both are always present rather than one being
  /// chosen based on the family.
  static TextTheme themeFor({
    required String fontFamily,
    required ThemeTypography typography,
    required Color bodyColor,
    required Color mutedColor,
  }) {
    TextStyle cut(TextStyle base, int weight, {Color? color}) {
      final size = base.fontSize == null
          ? null
          : (base.fontSize! * typography.scale);

      return base.copyWith(
        fontFamily: fontFamily,
        fontSize: size,
        // A delta rather than a replacement. The display styles are set at
        // -1.8 and the overline at +1.8; overwriting either with one absolute
        // value would destroy the register they belong to.
        letterSpacing: (base.letterSpacing ?? 0) + typography.letterSpacing,
        fontWeight: _weightOf(weight),
        fontVariations: <FontVariation>[FontVariation('wght', weight.toDouble())],
        color: color ?? base.color,
      );
    }

    final display = typography.weightDisplay;
    final bold = typography.weightBold;
    final medium = typography.weightMedium;
    final regular = typography.weightRegular;

    return TextTheme(
      displayLarge: cut(displayLarge, display, color: bodyColor),
      displayMedium: cut(displayMedium, display, color: bodyColor),
      displaySmall: cut(displaySmall, display, color: bodyColor),
      headlineLarge: cut(headlineLarge, bold, color: bodyColor),
      headlineMedium: cut(headlineMedium, bold, color: bodyColor),
      headlineSmall: cut(headlineSmall, bold, color: bodyColor),
      titleLarge: cut(headlineSmall, bold, color: bodyColor),
      titleMedium: cut(titleMedium, medium, color: bodyColor),
      titleSmall: cut(titleSmall, medium, color: bodyColor),
      bodyLarge: cut(bodyLarge, regular, color: bodyColor),
      bodyMedium: cut(bodyMedium, regular, color: mutedColor),
      bodySmall: cut(bodySmall, regular, color: mutedColor),
      labelLarge: cut(labelLarge, bold, color: bodyColor),
      labelMedium: cut(labelMedium, medium, color: mutedColor),
      labelSmall: cut(labelSmall, bold, color: mutedColor),
    );
  }

  /// The wordmark, re-cut. Kept out of [themeFor] because `TextTheme` has no
  /// slot for it and the brand widgets read it by name.
  static TextStyle wordmarkFor({
    required String fontFamily,
    required ThemeTypography typography,
    required Color color,
  }) => wordmark.copyWith(
    fontFamily: fontFamily,
    fontSize: wordmark.fontSize! * typography.scale,
    letterSpacing: (wordmark.letterSpacing ?? 0) + typography.letterSpacing,
    fontWeight: _weightOf(typography.weightDisplay),
    fontVariations: <FontVariation>[
      FontVariation('wght', typography.weightDisplay.toDouble()),
    ],
    color: color,
  );

  /// The timecode style, re-cut. Tabular figures are preserved — a timer whose
  /// digits change width jitters, which is the one thing this style exists to
  /// prevent.
  static TextStyle timecodeFor({
    required String fontFamily,
    required ThemeTypography typography,
    required Color color,
  }) => timecode.copyWith(
    fontFamily: fontFamily,
    fontSize: timecode.fontSize! * typography.scale,
    fontWeight: _weightOf(typography.weightMedium),
    fontVariations: <FontVariation>[
      FontVariation('wght', typography.weightMedium.toDouble()),
    ],
    color: color,
  );

  /// The nearest [FontWeight] to a numeric axis value.
  ///
  /// `FontWeight.values` is indexed in hundreds from 100, so this is arithmetic
  /// rather than a lookup table — and it clamps, so an axis value outside
  /// 100–900 resolves to an end of the range instead of throwing on an index.
  static FontWeight _weightOf(int weight) {
    final index = ((weight / 100).round() - 1).clamp(0, FontWeight.values.length - 1);
    return FontWeight.values[index];
  }
}
