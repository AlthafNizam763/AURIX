import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'theme_config.dart';

/// The brightness-aware half of the AURIX palette, carried on [ThemeData] so
/// widgets resolve it from context rather than importing a global.
///
/// Read it with `context.palette`.
///
/// ## Why this exists now that there is only one colourway
///
/// AURIX used to ship three colourways, and this extension carried the brand
/// hues that moved between them. With a single monochrome identity there are no
/// hues left to carry — but the extension became *more* necessary, not less,
/// because monochrome is the one palette where light mode cannot be a tint
/// change. Every token here genuinely swaps ends of the ramp between
/// brightnesses, and [AppColors] can only hold one of those ends as a
/// compile-time constant.
///
/// A widget that reads `AppColors.textPrimary` directly is therefore hard-coded
/// to dark mode. Reading `context.palette.textPrimary` is what makes it work in
/// both. [AppColors] remains the right source for `const` widget trees and
/// `CustomPainter` defaults, where its values act as the dark-mode fallback.
///
/// ## Light mode is not an inversion
///
/// Swapping black for white and calling it done produces a light theme that
/// looks like a bug. Two decisions here are deliberate departures:
///
///  * **Elevation reverses direction.** In dark mode a surface gets *lighter*
///    as it rises. In light mode the page is a resting off-white and cards rise
///    to pure white — so in both themes "raised" means "closer to the light",
///    and neither theme has a card that looks like a hole.
///  * **Light-mode ink is not #000000.** Pure black on pure white is the
///    highest-contrast pairing available and it is genuinely unpleasant to read
///    at body size — it haloes. [_lightInk] backs off to near-black, which
///    still clears AAA and is what every premium light interface actually does.
@immutable
class AurixPalette extends ThemeExtension<AurixPalette> {
  const AurixPalette({
    required this.brightness,
    required this.ground,
    required this.groundDeep,
    required this.surface,
    required this.surfaceElevated,
    required this.surfaceHighest,
    required this.accent,
    required this.accentPressed,
    required this.accentSoft,
    required this.textOnAccent,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.attention,
    required this.hairline,
    required this.hairlineStrong,
    required this.glassFill,
    required this.glassFillStrong,
    required this.glassBorder,
    required this.grain,
    required this.shimmerBase,
    required this.shimmerHighlight,
    required this.artworkPlaceholder,
    required this.brandGradient,
    required this.brandSurfaceHigh,
    required this.brandSurfaceLow,
    this.player = AppColors.surface,
    this.button = AppColors.accent,
  });

  final Brightness brightness;

  bool get isDark => brightness == Brightness.dark;

  // ---- Ground and surfaces ----------------------------------------------
  // Four stacked planes. Depth comes from stacking these, never from a border —
  // see the ramp note in [AppColors].

  /// The page itself.
  final Color ground;

  /// Recessed areas — the well behind a sunken control, the far end of a
  /// scrim.
  final Color groundDeep;

  final Color surface;
  final Color surfaceElevated;
  final Color surfaceHighest;

  // ---- Accent -----------------------------------------------------------

  /// The primary action colour: white on dark, near-black on light. The one
  /// token that fully changes ends of the ramp between themes.
  final Color accent;
  final Color accentPressed;
  final Color accentSoft;

  /// Sits *on* [accent]. 21:1 in dark, 19.3:1 in light.
  final Color textOnAccent;

  // ---- Text -------------------------------------------------------------
  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// The status tone: errors, warnings, "unavailable" notices.
  ///
  /// One token, because monochrome has no alarm hue to spend and separating
  /// four status levels by luminance alone would produce four greys nobody can
  /// tell apart. Every status surface pairs this with a glyph and a sentence —
  /// colour is never the only signal.
  ///
  /// It exists as its own field rather than as an alias for [textPrimary] so
  /// that the seam survives: if a destructive action ever needs a true red,
  /// this is the one value to change, and every call site picks it up.
  final Color attention;

  // ---- Lines, glass and texture -----------------------------------------
  final Color hairline;
  final Color hairlineStrong;

  /// Frosted-panel fill. Low-alpha on purpose: glass reads as glass because of
  /// the blur behind it, and a panel opaque enough to be legible on its own is
  /// just a card. In light mode this flips to a translucent *white* — frosting
  /// light content means adding light, not shade.
  final Color glassFill;
  final Color glassFillStrong;
  final Color glassBorder;

  /// Film grain, laid over large flat fields. In dark mode this is white at ~4%
  /// and its real job is dither: it is what stops a full-bleed black gradient
  /// from banding into visible steps on an OLED panel.
  final Color grain;

  final Color shimmerBase;
  final Color shimmerHighlight;

  /// Behind artwork that has not loaded yet.
  final Color artworkPlaceholder;

  // ---- Brand ------------------------------------------------------------
  final List<Color> brandGradient;
  final Color brandSurfaceHigh;
  final Color brandSurfaceLow;

  // ---- Player -----------------------------------------------------------

  /// The mini player and full player background.
  ///
  /// Its own token rather than an alias for [surface], because the player is
  /// the one surface an operator is expected to want different from the rest of
  /// the app — that is the premise of a separate player theme. Defaulting it to
  /// the surface tone is what keeps the shipped design unchanged.
  final Color player;

  /// Filled-button fill.
  ///
  /// Separate from [accent] so a design can have a loud play button and quiet
  /// buttons, or the reverse. Both default to the same value, which is why the
  /// monochrome identity looks identical whether or not an operator has ever
  /// opened the Appearance screen.
  final Color button;

  /// The ink that sits *on* [button], chosen for contrast rather than
  /// configured.
  ///
  /// Deliberately not an admin-settable role. An operator who picks a yellow
  /// button and a white label has made the label invisible, and no amount of
  /// UI copy prevents that reliably — so the label is computed from the fill's
  /// luminance and is always readable. The same reasoning applies to
  /// [textOnAccent], which [AurixPalette.fromConfig] computes the same way.
  Color get textOnButton => _inkFor(button);

  /// Two-stop gradient for surfaces where a third stop compresses into a muddy
  /// band.
  List<Color> get accentGradient => <Color>[
    brandGradient.first,
    brandGradient[brandGradient.length ~/ 2],
  ];

  /// The only glow AURIX has: the accent at an alpha.
  Color glow(double alpha) => accent.withValues(alpha: alpha);

  /// A neutral header gradient for content with no artwork to sample.
  List<Color> get neutralHeaderGradient => <Color>[
    surfaceHighest,
    surface,
    ground,
  ];

  // ---- The two themes ---------------------------------------------------

  /// Near-black rather than black. See the class note.
  static const Color _lightInk = Color(0xFF0A0A0A);

  /// Mirrors [AppColors] exactly — the constants there are this theme, which is
  /// why the `const` fallback and the resolved value are never out of step.
  static const AurixPalette dark = AurixPalette(
    brightness: Brightness.dark,
    ground: AppColors.background,
    groundDeep: AppColors.backgroundDeep,
    surface: AppColors.surface,
    surfaceElevated: AppColors.surfaceElevated,
    surfaceHighest: AppColors.surfaceHighest,
    accent: AppColors.accent,
    accentPressed: AppColors.accentPressed,
    accentSoft: AppColors.accentSoft,
    textOnAccent: AppColors.textOnAccent,
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
    textTertiary: AppColors.textTertiary,
    attention: AppColors.error,
    hairline: AppColors.divider,
    hairlineStrong: AppColors.dividerStrong,
    glassFill: AppColors.glassFill,
    glassFillStrong: AppColors.glassFillStrong,
    glassBorder: AppColors.glassBorder,
    grain: AppColors.grain,
    shimmerBase: AppColors.shimmerBase,
    shimmerHighlight: AppColors.shimmerHighlight,
    artworkPlaceholder: AppColors.artworkPlaceholder,
    brandGradient: AppColors.brandGradient,
    brandSurfaceHigh: AppColors.brandSurfaceHigh,
    brandSurfaceLow: AppColors.brandSurfaceLow,
  );

  /// Designed, not inverted. See the class note for the two departures.
  static const AurixPalette light = AurixPalette(
    brightness: Brightness.light,
    // The page rests slightly below white so that a card can rise *to* white.
    ground: Color(0xFFF2F2F2),
    groundDeep: Color(0xFFE8E8E8),
    surface: Color(0xFFFAFAFA),
    surfaceElevated: AppColors.white,
    surfaceHighest: AppColors.white,
    accent: _lightInk,
    // Pressed lifts toward graphite instead of dropping to true black: on a
    // near-black accent there is no darker step left, so the state change has
    // to come from the other direction.
    accentPressed: Color(0xFF2E2E2E),
    accentSoft: Color(0x1F0A0A0A),
    textOnAccent: AppColors.white,
    textPrimary: _lightInk,
    textSecondary: Color(0xFF5C5C5C),
    textTertiary: Color(0xFF8A8A8A),
    // Near-black, matching the light ink. On paper, "maximum attention" is
    // the darkest thing available — the exact inverse of the dark theme.
    attention: _lightInk,
    hairline: Color(0x14000000),
    hairlineStrong: Color(0x24000000),
    // Frosting light content means adding light, not shade — these are white,
    // where their dark-mode counterparts are white at a tenth of the alpha.
    glassFill: Color(0x99FFFFFF),
    glassFillStrong: Color(0xCCFFFFFF),
    glassBorder: Color(0x1F000000),
    grain: Color(0x08000000),
    shimmerBase: Color(0xFFE8E8E8),
    shimmerHighlight: Color(0xFFF7F7F7),
    artworkPlaceholder: Color(0xFFE4E4E4),
    brandGradient: <Color>[_lightInk, AppColors.gray, Color(0xFFF2F2F2)],
    brandSurfaceHigh: Color(0xFFFFFFFF),
    brandSurfaceLow: Color(0xFFE8E8E8),
  );

  static AurixPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  // ---- Built from configuration -----------------------------------------

  /// Builds the full palette from the eight roles an administrator can set.
  ///
  /// ## Why eight roles produce twenty-six tokens
  ///
  /// The palette a widget reads has a surface stack, hairlines, glass, grain,
  /// shimmer and a brand gradient. Exposing all of that in the admin panel
  /// would be a form nobody can fill in correctly — and it would let an
  /// operator produce combinations that are not merely ugly but unreadable,
  /// which is a different and worse thing.
  ///
  /// So the admin sets the eight roles that describe *intent*, and everything
  /// else is derived from them by rules that preserve the relationships the
  /// design depends on. The two that matter most:
  ///
  ///  * **Text steps are blends toward the background, not opacities.** A
  ///    secondary label at 60% alpha over artwork picks up the artwork; the
  ///    same colour blended against the background stays a flat grey, which is
  ///    what the monochrome design needs. It also means the derived steps stay
  ///    legible whichever way round the palette is.
  ///  * **Ink on a filled surface is computed, never configured.** An operator
  ///    who sets a yellow accent and a white label has made the play glyph
  ///    invisible. [_inkFor] picks black or white by luminance, so the control
  ///    is always readable regardless of what was chosen around it.
  ///
  /// ## What is deliberately not derived
  ///
  /// Nothing here tries to *correct* a bad palette — a background and a text
  /// colour that are both mid-grey will produce low-contrast text, and that is
  /// the operator's decision to make and to see. The derivation only guarantees
  /// the relationships it can compute honestly: ink on a fill, and the
  /// direction of the elevation stack.
  factory AurixPalette.fromConfig(ThemeConfig config, Brightness brightness) {
    final colors = config.colorsFor(brightness);
    final isDark = brightness == Brightness.dark;

    final ground = colors.background;
    final text = colors.text;

    // Elevation reverses direction between themes — in dark a raised surface
    // gets lighter, in light it rises toward white — so that "raised" means
    // "closer to the light" in both, and neither theme has a card that looks
    // like a hole. See the class note.
    final lift = isDark ? Colors.white : Colors.black;

    return AurixPalette(
      brightness: brightness,
      ground: ground,
      groundDeep: _shift(ground, isDark ? -0.35 : -0.05),
      surface: colors.surface,
      surfaceElevated: _blend(colors.surface, lift, 0.04),
      // The secondary role *is* the top surface step — chips, the highest card
      // — which is what its description in the admin panel says it paints.
      surfaceHighest: colors.secondary,
      accent: colors.accent,
      // A pressed accent moves *away* from wherever it sits on the ramp: a
      // near-black accent has no darker step left, so on light it lifts and on
      // dark it dims. A fixed direction breaks one of the two themes.
      accentPressed: _shift(colors.accent, isDark ? -0.06 : 0.18),
      accentSoft: colors.accent.withValues(alpha: 0.20),
      textOnAccent: _inkFor(colors.accent),
      textPrimary: text,
      // Blends toward the ground rather than alpha steps — see the class note.
      textSecondary: _blend(text, ground, 0.37),
      textTertiary: _blend(text, ground, 0.60),
      attention: colors.accent,
      hairline: text.withValues(alpha: 0.08),
      hairlineStrong: text.withValues(alpha: 0.14),
      // Frosting light content means adding light, not shade: the glass fill
      // takes the *lift* direction, so it is translucent white on dark and
      // translucent white on light too — at a much higher alpha, because a
      // panel over pale content needs more of it to read as a panel.
      glassFill: (isDark ? Colors.white : Colors.white).withValues(
        alpha: isDark ? 0.06 : 0.60,
      ),
      glassFillStrong: (isDark ? Colors.white : Colors.white).withValues(
        alpha: isDark ? 0.10 : 0.80,
      ),
      glassBorder: text.withValues(alpha: 0.12),
      // Dither, not decoration. This is what stops a full-bleed gradient from
      // banding into visible steps on an OLED panel, so it follows the text
      // colour — the one token guaranteed to contrast with the ground.
      grain: text.withValues(alpha: isDark ? 0.04 : 0.03),
      shimmerBase: colors.surface,
      shimmerHighlight: _blend(colors.surface, lift, 0.09),
      artworkPlaceholder: colors.surface,
      brandGradient: <Color>[colors.primary, colors.secondary, ground],
      brandSurfaceHigh: colors.surface,
      brandSurfaceLow: ground,
      player: colors.player,
      button: colors.button,
    );
  }

  /// Black or white, whichever is readable on [background].
  ///
  /// ## Why the threshold is 0.179 and not 0.5
  ///
  /// "Luminance above a half means use black ink" is the heuristic everyone
  /// reaches for, and it is wrong — badly, not marginally. WCAG contrast is
  ///
  /// ```
  ///   black ink on L  →  (L + 0.05) / 0.05
  ///   white ink on L  →  1.05 / (L + 0.05)
  /// ```
  ///
  /// At L = 0.49 the 0.5 rule picks white, which measures **1.9:1** — visually
  /// illegible. The two curves cross where `(L + 0.05)² = 0.0525`, at
  /// L ≈ 0.1791, and picking the better ink at *that* point is what maximises
  /// the worst case. It bottoms out at 4.58:1, which clears AA for body text
  /// with nothing to spare — that is the best any two-ink rule can do, and it
  /// is the guarantee `theme_config_test.dart` sweeps the whole sRGB cube to
  /// confirm.
  ///
  /// ## Why the dark ink here is pure black, not [_lightInk]
  ///
  /// Everywhere else in AURIX the dark ink backs off to near-black, because
  /// pure black on pure white haloes at body size. Here it cannot: #0A0A0A has
  /// a luminance of 0.005, which drags the worst case down to 4.2:1 and loses
  /// the guarantee this function exists to make. A glyph on a filled control is
  /// also not body copy — it is one shape at 26px, where the haloing argument
  /// does not apply.
  static const double _inkCrossover = 0.1791;

  static Color _inkFor(Color background) =>
      background.computeLuminance() > _inkCrossover
      ? Colors.black
      : Colors.white;

  /// Mixes [amount] of [toward] into [color].
  static Color _blend(Color color, Color toward, double amount) =>
      Color.lerp(color, toward, amount.clamp(0.0, 1.0))!;

  /// Moves a colour along the light/dark axis. Positive lightens.
  ///
  /// Works in HSL so a hue survives the move: mixing toward white desaturates,
  /// which turns a deep red accent into pink on its pressed state. Lightness is
  /// clamped rather than wrapped, so a colour already at an extreme simply
  /// stops there.
  static Color _shift(Color color, double amount) {
    final hsl = HSLColor.fromColor(color);
    final lightness = (hsl.lightness + amount).clamp(0.0, 1.0);
    return hsl.withLightness(lightness).toColor();
  }

  /// The contrast ratio between two colours, per WCAG 2.1.
  ///
  /// Exposed because the Appearance screen uses it to warn an administrator
  /// *before* they save a palette whose body text falls below AA — which is the
  /// one thing the derivation above cannot fix for them.
  static double contrastRatio(Color a, Color b) {
    final lighter = math.max(a.computeLuminance(), b.computeLuminance());
    final darker = math.min(a.computeLuminance(), b.computeLuminance());
    return (lighter + 0.05) / (darker + 0.05);
  }

  // ---- ThemeExtension ---------------------------------------------------

  @override
  AurixPalette copyWith({
    Brightness? brightness,
    Color? ground,
    Color? groundDeep,
    Color? surface,
    Color? surfaceElevated,
    Color? surfaceHighest,
    Color? accent,
    Color? accentPressed,
    Color? accentSoft,
    Color? textOnAccent,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? attention,
    Color? hairline,
    Color? hairlineStrong,
    Color? glassFill,
    Color? glassFillStrong,
    Color? glassBorder,
    Color? grain,
    Color? shimmerBase,
    Color? shimmerHighlight,
    Color? artworkPlaceholder,
    List<Color>? brandGradient,
    Color? brandSurfaceHigh,
    Color? brandSurfaceLow,
    Color? player,
    Color? button,
  }) {
    return AurixPalette(
      brightness: brightness ?? this.brightness,
      ground: ground ?? this.ground,
      groundDeep: groundDeep ?? this.groundDeep,
      surface: surface ?? this.surface,
      surfaceElevated: surfaceElevated ?? this.surfaceElevated,
      surfaceHighest: surfaceHighest ?? this.surfaceHighest,
      accent: accent ?? this.accent,
      accentPressed: accentPressed ?? this.accentPressed,
      accentSoft: accentSoft ?? this.accentSoft,
      textOnAccent: textOnAccent ?? this.textOnAccent,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      attention: attention ?? this.attention,
      hairline: hairline ?? this.hairline,
      hairlineStrong: hairlineStrong ?? this.hairlineStrong,
      glassFill: glassFill ?? this.glassFill,
      glassFillStrong: glassFillStrong ?? this.glassFillStrong,
      glassBorder: glassBorder ?? this.glassBorder,
      grain: grain ?? this.grain,
      shimmerBase: shimmerBase ?? this.shimmerBase,
      shimmerHighlight: shimmerHighlight ?? this.shimmerHighlight,
      artworkPlaceholder: artworkPlaceholder ?? this.artworkPlaceholder,
      brandGradient: brandGradient ?? this.brandGradient,
      brandSurfaceHigh: brandSurfaceHigh ?? this.brandSurfaceHigh,
      brandSurfaceLow: brandSurfaceLow ?? this.brandSurfaceLow,
      player: player ?? this.player,
      button: button ?? this.button,
    );
  }

  /// Interpolates every token, so a light/dark switch crossfades the whole
  /// surface stack through `MaterialApp`'s theme animation instead of snapping.
  /// The discrete [brightness] tag flips at the halfway point — there is no
  /// meaningful intermediate value for it, and flipping early would make a
  /// widget that branches on it change before the colours agree.
  @override
  AurixPalette lerp(covariant ThemeExtension<AurixPalette>? other, double t) {
    if (other is! AurixPalette) return this;
    return AurixPalette(
      brightness: t < 0.5 ? brightness : other.brightness,
      ground: Color.lerp(ground, other.ground, t)!,
      groundDeep: Color.lerp(groundDeep, other.groundDeep, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceElevated: Color.lerp(surfaceElevated, other.surfaceElevated, t)!,
      surfaceHighest: Color.lerp(surfaceHighest, other.surfaceHighest, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentPressed: Color.lerp(accentPressed, other.accentPressed, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      textOnAccent: Color.lerp(textOnAccent, other.textOnAccent, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      attention: Color.lerp(attention, other.attention, t)!,
      hairline: Color.lerp(hairline, other.hairline, t)!,
      hairlineStrong: Color.lerp(hairlineStrong, other.hairlineStrong, t)!,
      glassFill: Color.lerp(glassFill, other.glassFill, t)!,
      glassFillStrong: Color.lerp(glassFillStrong, other.glassFillStrong, t)!,
      glassBorder: Color.lerp(glassBorder, other.glassBorder, t)!,
      grain: Color.lerp(grain, other.grain, t)!,
      shimmerBase: Color.lerp(shimmerBase, other.shimmerBase, t)!,
      shimmerHighlight:
          Color.lerp(shimmerHighlight, other.shimmerHighlight, t)!,
      artworkPlaceholder:
          Color.lerp(artworkPlaceholder, other.artworkPlaceholder, t)!,
      brandGradient: <Color>[
        for (var i = 0; i < brandGradient.length; i++)
          Color.lerp(
            brandGradient[i],
            // Guard the index: the gradients happen to be the same length, but
            // a future gradient with a different stop count should degrade to
            // "hold the last stop" rather than throw mid-animation.
            other.brandGradient[i.clamp(0, other.brandGradient.length - 1)],
            t,
          )!,
      ],
      brandSurfaceHigh: Color.lerp(brandSurfaceHigh, other.brandSurfaceHigh, t)!,
      brandSurfaceLow: Color.lerp(brandSurfaceLow, other.brandSurfaceLow, t)!,
      player: Color.lerp(player, other.player, t)!,
      button: Color.lerp(button, other.button, t)!,
    );
  }
}

/// Resolves the palette from context.
///
/// Falls back to [AurixPalette.dark] rather than throwing when no extension is
/// registered, so a widget test that mounts a bare `MaterialApp` still renders
/// the brand instead of crashing on a null assertion.
extension AurixPaletteContext on BuildContext {
  AurixPalette get palette =>
      Theme.of(this).extension<AurixPalette>() ?? AurixPalette.dark;
}
