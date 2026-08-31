import 'package:aurix/core/theme/app_colors.dart';
import 'package:aurix/core/theme/aurix_palette.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG 2.1 contrast ratio between two opaque colours.
///
/// `Color.computeLuminance()` is Flutter's implementation of WCAG relative
/// luminance, so this is the real formula rather than an approximation.
double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final lighter = la > lb ? la : lb;
  final darker = la > lb ? lb : la;
  return (lighter + 0.05) / (darker + 0.05);
}

/// True when a colour has no chroma at all — red, green and blue channels
/// exactly equal.
bool isNeutral(Color c) => c.r == c.g && c.g == c.b;

/// Guards the palette against a well-meaning colour tweak quietly making text
/// unreadable, and against the *specific* failure a monochrome system invites:
/// somebody reaching for a hue because greys felt flat.
///
/// The second one is what most of this file is about. A palette with no colour
/// has one axis to spend, so every check here is either "is there enough
/// luminance difference" or "is there still no hue".
void main() {
  Matcher atLeast(double ratio) => greaterThanOrEqualTo(ratio);

  void check(
    String label,
    Color foreground,
    Color background,
    double minimum,
  ) {
    final ratio = contrast(foreground, background);
    expect(
      ratio,
      atLeast(minimum),
      reason: '$label measured ${ratio.toStringAsFixed(2)}:1, '
          'needs ${minimum.toStringAsFixed(1)}:1',
    );
  }

  // ---- The invariant ------------------------------------------------------

  group('the palette is actually monochrome', () {
    // This is the identity, expressed as a test. AURIX can survive a spacing
    // regression; it cannot survive a hue appearing in the ramp, because the
    // entire design — the white play button outranking everything, the
    // greyscaled artwork backdrop, luminance-only status — is built on the
    // assumption that nothing else on screen carries colour.
    test('every ramp step is a pure neutral', () {
      const ramp = <String, Color>{
        'black': AppColors.black,
        'blackDeep': AppColors.blackDeep,
        'surfaceDark': AppColors.surfaceDark,
        'surfaceElevatedTone': AppColors.surfaceElevatedTone,
        'graphite': AppColors.graphite,
        'gray': AppColors.gray,
        'grayLight': AppColors.grayLight,
        'white': AppColors.white,
        'whiteSoft': AppColors.whiteSoft,
      };

      ramp.forEach((name, colour) {
        expect(
          isNeutral(colour),
          isTrue,
          reason: '$name has chroma: '
              'r=${colour.r} g=${colour.g} b=${colour.b}',
        );
      });
    });

    test('every status colour is a pure neutral', () {
      // Status is separated by luminance and an accompanying glyph, never by
      // hue. If a red ever lands back in `error`, the call sites that pair it
      // with an icon become redundant and the ones that do not become the
      // app's only splash of colour.
      for (final entry in <String, Color>{
        'error': AppColors.error,
        'warning': AppColors.warning,
        'success': AppColors.success,
        'info': AppColors.info,
      }.entries) {
        expect(
          isNeutral(entry.value),
          isTrue,
          reason: '${entry.key} carries a hue',
        );
      }
    });

    test('both themes are neutral end to end', () {
      for (final theme in <String, AurixPalette>{
        'dark': AurixPalette.dark,
        'light': AurixPalette.light,
      }.entries) {
        final p = theme.value;
        for (final entry in <String, Color>{
          'ground': p.ground,
          'groundDeep': p.groundDeep,
          'surface': p.surface,
          'surfaceElevated': p.surfaceElevated,
          'surfaceHighest': p.surfaceHighest,
          'accent': p.accent,
          'accentPressed': p.accentPressed,
          'textOnAccent': p.textOnAccent,
          'textPrimary': p.textPrimary,
          'textSecondary': p.textSecondary,
          'textTertiary': p.textTertiary,
          'artworkPlaceholder': p.artworkPlaceholder,
          'shimmerBase': p.shimmerBase,
          'shimmerHighlight': p.shimmerHighlight,
        }.entries) {
          expect(
            isNeutral(entry.value),
            isTrue,
            reason: '${theme.key}.${entry.key} carries a hue',
          );
        }
      }
    });

    test('the ramp is ordered, with a gap where the design needs one', () {
      // The four dark steps cluster tightly so they can stack as layers; then
      // there is a deliberate void before mid-grey, which is what makes text
      // pop off a card rather than fade into it. See the note in AppColors.
      final steps = <Color>[
        AppColors.black,
        AppColors.blackDeep,
        AppColors.surfaceDark,
        AppColors.surfaceElevatedTone,
        AppColors.graphite,
        AppColors.gray,
        AppColors.grayLight,
        AppColors.whiteSoft,
        AppColors.white,
      ];

      for (var i = 1; i < steps.length; i++) {
        expect(
          steps[i].computeLuminance(),
          greaterThan(steps[i - 1].computeLuminance()),
          reason: 'ramp step $i is not lighter than step ${i - 1}',
        );
      }

      final graphiteToGray =
          contrast(AppColors.gray, AppColors.graphite);
      final tightestDarkStep =
          contrast(AppColors.surfaceElevatedTone, AppColors.surfaceDark);
      expect(
        graphiteToGray,
        greaterThan(tightestDarkStep * 2),
        reason: 'the void between graphite and mid-grey has closed up — the '
            'surface stack and the text tones are merging into one ramp',
      );
    });
  });

  // ---- Dark: the primary experience --------------------------------------

  group('dark theme — text on surfaces (AA normal text 4.5:1)', () {
    test('primary text on every dark surface', () {
      check('textPrimary/background', AppColors.textPrimary, AppColors.background, 4.5);
      check('textPrimary/surface', AppColors.textPrimary, AppColors.surface, 4.5);
      check(
        'textPrimary/surfaceElevated',
        AppColors.textPrimary,
        AppColors.surfaceElevated,
        4.5,
      );
      check(
        'textPrimary/surfaceHighest',
        AppColors.textPrimary,
        AppColors.surfaceHighest,
        4.5,
      );
    });

    test('secondary text stays readable', () {
      check('textSecondary/background', AppColors.textSecondary, AppColors.background, 4.5);
      check('textSecondary/surface', AppColors.textSecondary, AppColors.surface, 4.5);
    });

    test('tertiary text clears the large-text floor on the page', () {
      // Metadata and overlines only. 3:1 is the applicable floor for the sizes
      // this tone is used at; anything set in it at body size is a bug.
      check('textTertiary/background', AppColors.textTertiary, AppColors.background, 3.0);
    });
  });

  group('dark theme — the accent', () {
    test('the play button clears AA by a wide margin', () {
      // Black on white: 21:1, the highest the sRGB space allows. The margin is
      // the point — this pairing is what makes the primary control outrank a
      // screen full of greys.
      check('textOnAccent/accent', AppColors.textOnAccent, AppColors.accent, 4.5);
      expect(
        contrast(AppColors.textOnAccent, AppColors.accent),
        atLeast(20),
      );
    });

    test('dark-on-accent beats white-on-accent', () {
      // Documents *why* the accent carries black rather than white. Trivially
      // true now that the accent is white, and worth keeping: it is the check
      // that fails first if the accent is ever darkened.
      final dark = contrast(AppColors.textOnAccent, AppColors.accent);
      final light = contrast(AppColors.textPrimary, AppColors.accent);
      expect(
        dark,
        greaterThan(light),
        reason: 'dark ${dark.toStringAsFixed(2)}:1 vs '
            'white ${light.toStringAsFixed(2)}:1',
      );
    });

    test('the pressed state also clears AA', () {
      check(
        'textOnAccent/accentPressed',
        AppColors.textOnAccent,
        AppColors.accentPressed,
        4.5,
      );
    });

    test('pressing visibly dims the disc without dropping the glyph', () {
      // The press state is a step *down* the ramp rather than a colour change,
      // so it has to be big enough to see and small enough to stay legible.
      expect(
        AppColors.accentPressed.computeLuminance(),
        lessThan(AppColors.accent.computeLuminance()),
        reason: 'the pressed accent is not darker than the resting one',
      );
      check(
        'textOnAccent/accentPressed',
        AppColors.textOnAccent,
        AppColors.accentPressed,
        7.0,
      );
    });

    test('the accent is visible as a graphical element (AA non-text 3:1)', () {
      // Progress bars, the now-playing equaliser and active tab icons are
      // shapes, not text, so 3:1 is the applicable floor.
      check('accent/background', AppColors.accent, AppColors.background, 3.0);
      check('accent/surface', AppColors.accent, AppColors.surface, 3.0);
    });
  });

  // ---- Light: designed, not inverted --------------------------------------

  group('light theme', () {
    const light = AurixPalette.light;

    test('text on every light surface clears AA', () {
      check('textPrimary/ground', light.textPrimary, light.ground, 4.5);
      check('textPrimary/surface', light.textPrimary, light.surface, 4.5);
      check(
        'textPrimary/surfaceElevated',
        light.textPrimary,
        light.surfaceElevated,
        4.5,
      );
      check('textSecondary/ground', light.textSecondary, light.ground, 4.5);
      check('textSecondary/surface', light.textSecondary, light.surface, 4.5);
    });

    test('the accent pairing clears AA in light too', () {
      check('textOnAccent/accent', light.textOnAccent, light.accent, 4.5);
      check(
        'textOnAccent/accentPressed',
        light.textOnAccent,
        light.accentPressed,
        4.5,
      );
      check('accent/ground', light.accent, light.ground, 3.0);
    });

    test('elevation reverses direction rather than inverting', () {
      // In dark, a surface gets lighter as it rises. In light it also gets
      // lighter — the page rests below white so a card can rise *to* white.
      // A mechanical inversion would have produced the opposite, and cards
      // that look like holes punched in the page.
      expect(
        light.surfaceElevated.computeLuminance(),
        greaterThan(light.ground.computeLuminance()),
        reason: 'light-mode cards are darker than the page — this is the '
            'mechanical inversion the theme is explicitly not',
      );
      expect(
        AurixPalette.dark.surfaceElevated.computeLuminance(),
        greaterThan(AurixPalette.dark.ground.computeLuminance()),
      );
    });

    test('light ink is not pure black', () {
      // Pure black on white haloes at body size. Near-black still clears AAA.
      expect(light.textPrimary, isNot(AppColors.black));
      expect(
        contrast(light.textPrimary, light.surfaceElevated),
        atLeast(7.0),
        reason: 'backing off from pure black has cost AAA',
      );
    });

    test('the two themes genuinely swap ends of the ramp', () {
      expect(
        light.accent.computeLuminance(),
        lessThan(AurixPalette.dark.accent.computeLuminance()),
      );
      expect(
        light.textOnAccent.computeLuminance(),
        greaterThan(AurixPalette.dark.textOnAccent.computeLuminance()),
      );
    });
  });

  // ---- Textures -----------------------------------------------------------

  group('textures stay textures', () {
    test('glass and grain stay subtle', () {
      // High alpha here is the difference between "frosted panel" and "grey
      // box", and between "film grain" and "visible speckle".
      expect(AppColors.glassFill.a, lessThan(0.2));
      expect(AppColors.glassBorder.a, lessThan(0.3));
      expect(AppColors.grain.a, lessThan(0.1));
    });

    test('light-mode glass frosts with white, not shade', () {
      // Frosting light content means adding light. A dark low-alpha fill over
      // a white page reads as a smudge, not as glass.
      expect(AurixPalette.light.glassFill.computeLuminance(), greaterThan(0.5));
      expect(AurixPalette.dark.glassFill.a, lessThan(0.3));
    });

    test('the shimmer never outshines real content', () {
      // A loading skeleton brighter than the thing it stands in for reads as a
      // defect rather than as loading.
      expect(
        AppColors.shimmerHighlight.computeLuminance(),
        lessThan(AppColors.textSecondary.computeLuminance()),
      );
      expect(
        AppColors.shimmerHighlight.computeLuminance(),
        greaterThan(AppColors.shimmerBase.computeLuminance()),
      );
    });
  });

  // ---- Fallback consistency ----------------------------------------------

  group('the const fallback matches the live theme', () {
    test('AurixPalette.dark mirrors AppColors', () {
      // AppColors carries the compile-time constants that `const` widget trees
      // and painter defaults fall back to. If these drift, those fallbacks
      // quietly render a different tone from the live theme.
      const dark = AurixPalette.dark;
      expect(dark.accent, AppColors.accent);
      expect(dark.accentPressed, AppColors.accentPressed);
      expect(dark.textOnAccent, AppColors.textOnAccent);
      expect(dark.ground, AppColors.background);
      expect(dark.surface, AppColors.surface);
      expect(dark.surfaceElevated, AppColors.surfaceElevated);
      expect(dark.surfaceHighest, AppColors.surfaceHighest);
      expect(dark.textPrimary, AppColors.textPrimary);
      expect(dark.textSecondary, AppColors.textSecondary);
      expect(dark.textTertiary, AppColors.textTertiary);
      expect(dark.grain, AppColors.grain);
      expect(dark.brandGradient, AppColors.brandGradient);
    });

    test('AurixPalette.of picks the right theme', () {
      expect(AurixPalette.of(Brightness.dark), AurixPalette.dark);
      expect(AurixPalette.of(Brightness.light), AurixPalette.light);
    });
  });

  group('placeholder tints', () {
    test('every artwork placeholder keeps its fallback icon visible', () {
      // Cards with no artwork draw a music-note icon over a deterministic tint;
      // a tint that swallowed the icon would look broken.
      for (final seed in ['a', 'album_1', 'artist_9', 'playlist_z', '']) {
        final tint = AppColors.placeholderFor(seed);
        check('placeholder($seed)', AppColors.textPrimary, tint, 3.0);
      }
    });

    test('every placeholder tint is neutral', () {
      for (final seed in ['a', 'album_1', 'artist_9', 'playlist_z', '']) {
        expect(
          isNeutral(AppColors.placeholderFor(seed)),
          isTrue,
          reason: 'placeholder($seed) carries a hue',
        );
      }
    });

    test('placeholders stay behind real artwork', () {
      // They sit in the dark cluster on purpose: a placeholder that competes
      // with a real cover defeats the point of having one.
      for (final seed in ['a', 'album_1', 'artist_9']) {
        expect(
          AppColors.placeholderFor(seed).computeLuminance(),
          lessThan(AppColors.gray.computeLuminance()),
        );
      }
    });

    test('the same seed always yields the same tint', () {
      expect(
        AppColors.placeholderFor('album_1'),
        AppColors.placeholderFor('album_1'),
      );
    });
  });
}
