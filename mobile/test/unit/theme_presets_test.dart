import 'package:aurix/core/theme/aurix_palette.dart';
import 'package:aurix/core/theme/theme_config.dart';
import 'package:aurix/core/theme/theme_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The preset colourways, and the two properties they have to hold.
///
/// A preset is the one place an administrator changes sixteen colours without
/// seeing any of them first. That makes it the one place where a bad value is
/// not caught by the person applying it, so the checks here are about what the
/// tap *cannot* be allowed to do: make the app unreadable, or lose work that
/// was not a colour.
void main() {
  // ---- Identity -----------------------------------------------------------

  group('preset identity', () {
    test('every selectable preset supplies both colourways', () {
      for (final preset in ThemePresets.selectable) {
        expect(
          ThemePresets.dark(preset),
          isNotNull,
          reason: '${preset.label} has no dark colourway',
        );
        expect(
          ThemePresets.light(preset),
          isNotNull,
          reason: '${preset.label} has no light colourway',
        );
      }
    });

    test('custom supplies neither — it is a state, not a choice', () {
      expect(ThemePresets.dark(ThemePreset.custom), isNull);
      expect(ThemePresets.light(ThemePreset.custom), isNull);
      expect(ThemePresets.selectable, isNot(contains(ThemePreset.custom)));
    });

    test('the default preset is exactly what the app ships with', () {
      // If these drift, a deployment that has never touched the theme would
      // show "Custom" on a config it never edited.
      expect(ThemePresets.dark(ThemePreset.aurix), ThemeConfig.fallback.dark);
      expect(ThemePresets.light(ThemePreset.aurix), ThemeConfig.fallback.light);
    });

    test('AMOLED keeps the shipped light colourway', () {
      // An unlit pixel is a dark-mode idea, so AMOLED deliberately has no light
      // variant of its own. Asserted rather than assumed, because a copy that
      // drifted from the fallback would make AMOLED unrecognisable to
      // `matching` while looking identical on screen.
      expect(ThemePresets.light(ThemePreset.amoled), ThemeConfig.fallback.light);
    });

    test('no two presets share a colourway pair', () {
      // Two identical presets would make `matching` return whichever came
      // first, so one of the radio buttons could never be shown as selected.
      for (final a in ThemePresets.selectable) {
        for (final b in ThemePresets.selectable) {
          if (a == b) continue;
          final same =
              ThemePresets.dark(a) == ThemePresets.dark(b) &&
              ThemePresets.light(a) == ThemePresets.light(b);
          expect(same, isFalse, reason: '${a.label} and ${b.label} are the same theme');
        }
      }
    });

    test('AMOLED is actually black, which is the whole point', () {
      // Not decoration: on an OLED panel this is the difference between a lit
      // pixel and an unlit one. A "nearly black" value would quietly cost the
      // battery saving the preset exists to deliver.
      expect(ThemePresets.dark(ThemePreset.amoled)!.background, const Color(0xFF000000));
    });
  });

  // ---- Round trip ---------------------------------------------------------

  group('applying and detecting', () {
    test('applying a preset makes it the matching one', () {
      for (final preset in ThemePresets.selectable) {
        final applied = ThemePresets.apply(ThemeConfig.fallback, preset);
        expect(
          ThemePresets.matching(applied),
          preset,
          reason: '${preset.label} was not detected after being applied',
        );
      }
    });

    test('the shipped config reads as the default preset, not as custom', () {
      expect(ThemePresets.matching(ThemeConfig.fallback), ThemePreset.aurix);
    });

    test('touching one colour makes the selection custom', () {
      final midnight = ThemePresets.apply(ThemeConfig.fallback, ThemePreset.midnight);
      final dark = midnight.dark;

      final edited = midnight.copyWith(
        dark: ThemeColors(
          primary: dark.primary,
          secondary: dark.secondary,
          // One picker moved. That is all it should take.
          accent: const Color(0xFF00FF00),
          background: dark.background,
          surface: dark.surface,
          text: dark.text,
          player: dark.player,
          button: dark.button,
        ),
      );

      expect(ThemePresets.matching(edited), ThemePreset.custom);
    });

    test('a half-applied preset is custom, not the preset', () {
      // Midnight's dark over the shipped light. Reporting this as "Midnight"
      // would mean a later tap on Midnight discarded the light colourway while
      // appearing to do nothing.
      final half = ThemeConfig.fallback.copyWith(
        dark: ThemePresets.dark(ThemePreset.midnight),
      );
      expect(ThemePresets.matching(half), ThemePreset.custom);
    });

    test('applying custom is a no-op rather than a wipe', () {
      final midnight = ThemePresets.apply(ThemeConfig.fallback, ThemePreset.midnight);
      expect(ThemePresets.apply(midnight, ThemePreset.custom), midnight);
    });

    test('a preset writes both colourways, whichever is being edited', () {
      final applied = ThemePresets.apply(ThemeConfig.fallback, ThemePreset.spiderVerse);
      expect(applied.dark, ThemePresets.dark(ThemePreset.spiderVerse));
      expect(applied.light, ThemePresets.light(ThemePreset.spiderVerse));
    });

    test('a preset changes nothing that is not a colour', () {
      // Someone who chose Poppins and then tried Midnight has not asked to
      // lose Poppins.
      final before = ThemeConfig.fallback.copyWith(
        fontFamily: 'Poppins',
        fontAssetId: 'font-123',
        appLogo: 'https://example.test/logo.png',
        typography: ThemeConfig.fallback.typography.copyWith(scale: 1.25),
      );
      final after = ThemePresets.apply(before, ThemePreset.amoled);

      expect(after.fontFamily, 'Poppins');
      expect(after.fontAssetId, 'font-123');
      expect(after.appLogo, 'https://example.test/logo.png');
      expect(after.typography.scale, 1.25);
      expect(after.musicPlayer, before.musicPlayer);
      expect(after.version, before.version);
    });
  });

  // ---- Legibility ---------------------------------------------------------

  group('every preset is readable', () {
    /// WCAG AA for body text. The floor, not the target.
    const double bodyMinimum = 4.5;

    /// WCAG AA for large text and UI components. Buttons and chips are held to
    /// this rather than to 4.5 because they are set at display sizes and, in
    /// the button's case, are a filled shape rather than a glyph.
    const double largeMinimum = 3.0;

    void check(String label, Color foreground, Color background, double minimum) {
      final ratio = AurixPalette.contrastRatio(foreground, background);
      expect(
        ratio,
        greaterThanOrEqualTo(minimum),
        reason: '$label measured ${ratio.toStringAsFixed(2)}:1, '
            'needs ${minimum.toStringAsFixed(1)}:1',
      );
    }

    for (final preset in ThemePresets.selectable) {
      test('${preset.label} keeps text legible in both colourways', () {
        for (final entry in <String, ThemeColors>{
          'dark': ThemePresets.dark(preset)!,
          'light': ThemePresets.light(preset)!,
        }.entries) {
          final where = '${preset.label} (${entry.key})';
          final c = entry.value;

          // The three surfaces text is actually set on. The player is included
          // because it is its own role precisely so it can differ from
          // `surface` — which means it can differ into illegibility.
          check('$where text on background', c.text, c.background, bodyMinimum);
          check('$where text on surface', c.text, c.surface, bodyMinimum);
          check('$where text on player', c.text, c.player, bodyMinimum);

          // Headings and the active tab.
          check('$where primary on background', c.primary, c.background, largeMinimum);

          // The accent and the button have to be *findable* against the ground
          // they sit on, or the one thing to press disappears.
          check('$where accent on background', c.accent, c.background, largeMinimum);
          check('$where button on background', c.button, c.background, largeMinimum);
          check('$where button on surface', c.button, c.surface, largeMinimum);
        }
      });
    }

    test('a dark preset is dark and a light one is light', () {
      // Cheap, and it catches the copy-paste that swaps the two — which
      // otherwise ships as an app that inverts when the phone changes mode.
      for (final preset in ThemePresets.selectable) {
        expect(
          ThemePresets.dark(preset)!.background.computeLuminance(),
          lessThan(0.2),
          reason: '${preset.label} dark background is not dark',
        );
        expect(
          ThemePresets.light(preset)!.background.computeLuminance(),
          greaterThan(0.5),
          reason: '${preset.label} light background is not light',
        );
      }
    });
  });

  // ---- Serialisation ------------------------------------------------------

  test('a preset survives the wire format', () {
    // Presets are stored as ordinary colours, not as a name, so a config saved
    // under one must come back recognisable. This is what makes the selection
    // survive a restart without the server learning a new field.
    for (final preset in ThemePresets.selectable) {
      final applied = ThemePresets.apply(ThemeConfig.fallback, preset);
      final json = <String, dynamic>{
        'version': applied.version,
        'fontFamily': applied.fontFamily,
        'colors': <String, dynamic>{
          'dark': applied.dark.toJson(),
          'light': applied.light.toJson(),
        },
      };

      expect(
        ThemePresets.matching(ThemeConfig.fromJson(json)),
        preset,
        reason: '${preset.label} was not recognisable after a round trip',
      );
    }
  });
}
