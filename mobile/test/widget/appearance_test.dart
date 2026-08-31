import 'package:aurix/core/theme/app_typography.dart';
import 'package:aurix/core/theme/aurix_palette.dart';
import 'package:aurix/core/theme/theme_config.dart';
import 'package:aurix/core/theme/theme_presets.dart';
import 'package:aurix/data/services/api/api_theme_service.dart';
import 'package:aurix/features/settings/widgets/appearance_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

/// What the theme system is *for*: a configuration document in MongoDB
/// reaching the pixels.
///
/// The unit tests cover parsing and derivation. These cover the half that
/// cannot be asserted on a value object — that the derived palette actually
/// arrives in `ThemeData`, that a widget reading `context.palette` sees the
/// operator's colours rather than the shipped ones, and that the admin controls
/// report what a user actually chose.
void main() {
  /// A configuration no shipped AURIX would produce, so a widget rendering the
  /// default is unmistakable in a failure.
  const branded = ThemeConfig(
    version: 9,
    fontFamily: 'Manrope',
    typography: ThemeTypography(
      scale: 1.2,
      letterSpacing: 0.5,
      weightRegular: 300,
      weightMedium: 500,
      weightBold: 800,
      weightDisplay: 900,
    ),
    dark: ThemeColors(
      primary: Color(0xFFFFFFFF),
      secondary: Color(0xFF1E1E24),
      accent: Color(0xFFE50914),
      background: Color(0xFF0B0B0F),
      surface: Color(0xFF15151C),
      text: Color(0xFFF5F5F7),
      player: Color(0xFF101018),
      button: Color(0xFFFFD400),
    ),
    light: ThemeColors(
      primary: Color(0xFF101018),
      secondary: Color(0xFFEFEFF4),
      accent: Color(0xFFE50914),
      background: Color(0xFFFFFFFF),
      surface: Color(0xFFF7F7FA),
      text: Color(0xFF101018),
      player: Color(0xFFF0F0F5),
      button: Color(0xFFFFD400),
    ),
    musicPlayer: PlayerThemes(
      mini: PlayerVariant.theme2,
      large: PlayerVariant.theme3,
      outside: PlayerVariant.theme1,
      dynamic: PlayerVariant.theme2,
    ),
  );

  group('a configured theme reaches the widget tree', () {
    testWidgets('the palette a widget reads is the configured one', (tester) async {
      late AurixPalette seen;

      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              seen = context.palette;
              return const SizedBox.shrink();
            },
          ),
          theme: branded,
        ),
      );

      expect(seen.ground, branded.dark.background);
      expect(seen.accent, branded.dark.accent);
      expect(seen.player, branded.dark.player);
      expect(seen.button, branded.dark.button);
    });

    testWidgets('the type scale is applied to the text theme', (tester) async {
      late TextTheme configured;

      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              configured = Theme.of(context).textTheme;
              return const SizedBox.shrink();
            },
          ),
          theme: branded,
        ),
      );

      // Compared against the shipped constants rather than against a second
      // pump: `MaterialApp` animates between themes, so a tree pumped once
      // after a theme change is still mid-interpolation and reports neither
      // value.
      expect(
        configured.bodyMedium!.fontSize,
        closeTo(AppTypography.bodyMedium.fontSize! * 1.2, 0.01),
      );
      expect(
        configured.displayLarge!.fontSize,
        closeTo(AppTypography.displayLarge.fontSize! * 1.2, 0.01),
      );

      // Tracking is a delta, not a replacement: the display register keeps its
      // negative tracking, shifted.
      expect(
        configured.displayLarge!.letterSpacing,
        closeTo(AppTypography.displayLarge.letterSpacing! + 0.5, 0.01),
      );
      expect(
        configured.displayLarge!.letterSpacing,
        lessThan(0),
        reason: 'a display style must not end up positively tracked',
      );
    });

    testWidgets('the configured weights reach the variable-font axis', (tester) async {
      late TextTheme text;

      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              text = Theme.of(context).textTheme;
              return const SizedBox.shrink();
            },
          ),
          theme: branded,
        ),
      );

      // Both are set, and both matter — see the note in AppTypography. The axis
      // is what renders on a variable font; `fontWeight` is what a non-variable
      // uploaded font honours, and what `TextStyle.lerp` uses.
      expect(
        text.bodyMedium!.fontVariations,
        contains(const FontVariation('wght', 300)),
      );
      expect(text.bodyMedium!.fontWeight, FontWeight.w300);
      expect(
        text.displayLarge!.fontVariations,
        contains(const FontVariation('wght', 900)),
      );
    });

    testWidgets('a filled button gets ink that is readable on it', (tester) async {
      // The yellow button in `branded` would be illegible with the white label
      // the monochrome identity uses.
      late ThemeData theme;

      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              theme = Theme.of(context);
              return const SizedBox.shrink();
            },
          ),
          theme: branded,
        ),
      );

      final style = theme.filledButtonTheme.style!;
      final background = style.backgroundColor!.resolve(<WidgetState>{})!;
      final foreground = style.foregroundColor!.resolve(<WidgetState>{})!;

      expect(background, branded.dark.button);
      expect(
        AurixPalette.contrastRatio(foreground, background),
        greaterThanOrEqualTo(4.5),
      );
    });
  });

  group('the appearance controls', () {
    testWidgets('the font picker marks the selected family', (tester) async {
      String? chosen;

      await tester.pumpWidget(
        wrapForTest(
          FontPicker(
            selected: 'Inter',
            options: const [
              FontOptionStub('Manrope', bundled: true, available: true),
              FontOptionStub('Inter', bundled: false, available: true),
              FontOptionStub('Oswald', bundled: false, available: false),
            ].map((s) => s.toOption()).toList(),
            onSelected: (font) => chosen = font.family,
          ),
        ),
      );

      expect(find.text('Inter'), findsOneWidget);

      // A family with no font file is listed but not selectable — hiding it
      // would make "where is Oswald?" unanswerable from inside the app.
      expect(
        find.text('No font file uploaded yet — add one in the web console.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Oswald'));
      await tester.pump();
      expect(chosen, isNull);

      await tester.tap(find.text('Manrope'));
      await tester.pump();
      expect(chosen, 'Manrope');
    });

    testWidgets('the player picker reports the variant that was tapped',
        (tester) async {
      PlayerVariant? chosen;

      await tester.pumpWidget(
        wrapForTest(
          PlayerVariantPicker(
            surface: PlayerSurface.large,
            selected: PlayerVariant.theme1,
            onSelected: (variant) => chosen = variant,
          ),
        ),
      );

      expect(find.text('Large player'), findsOneWidget);
      // All three, always — an operator has to be able to see what they are
      // choosing between.
      expect(find.text('Theme 1'), findsOneWidget);
      expect(find.text('Theme 3'), findsOneWidget);

      await tester.tap(find.text('Theme 3'));
      await tester.pump();
      expect(chosen, PlayerVariant.theme3);
    });

    testWidgets('an unreadable palette is called out before it ships',
        (tester) async {
      // The one thing the derivation cannot fix for an administrator: a
      // background and a text colour that are both mid-grey is a decision, and
      // the only honest response is to say so.
      await tester.pumpWidget(
        wrapForTest(
          const ContrastNotice(
            colors: ThemeColors(
              primary: Color(0xFF777777),
              secondary: Color(0xFF777777),
              accent: Color(0xFF777777),
              background: Color(0xFF6E6E6E),
              surface: Color(0xFF777777),
              text: Color(0xFF808080),
              player: Color(0xFF777777),
              button: Color(0xFF777777),
            ),
          ),
        ),
      );

      expect(find.textContaining('WCAG AA'), findsOneWidget);
    });

    testWidgets('a readable palette says nothing at all', (tester) async {
      await tester.pumpWidget(
        wrapForTest(ContrastNotice(colors: ThemeConfig.fallback.dark)),
      );
      expect(find.textContaining('WCAG'), findsNothing);
    });

    testWidgets('the preset picker offers every named colourway',
        (tester) async {
      await tester.pumpWidget(
        wrapForTest(
          ThemePresetPicker(
            selected: ThemePreset.aurix,
            onSelected: (_) {},
          ),
        ),
      );

      for (final preset in ThemePresets.selectable) {
        expect(
          find.text(preset.label),
          findsOneWidget,
          reason: '${preset.label} is missing from the picker',
        );
      }

      // Custom is not a thing to choose — it is what the app calls the colours
      // you already have — so it is absent unless it is the current selection.
      expect(find.text('Custom'), findsNothing);
    });

    testWidgets('the preset picker reports the colourway that was tapped',
        (tester) async {
      ThemePreset? chosen;

      await tester.pumpWidget(
        wrapForTest(
          ThemePresetPicker(
            selected: ThemePreset.aurix,
            onSelected: (preset) => chosen = preset,
          ),
        ),
      );

      await tester.tap(find.text('Midnight'));
      await tester.pump();
      expect(chosen, ThemePreset.midnight);
    });

    testWidgets('Custom appears, unselectable, once the colours are hand-mixed',
        (tester) async {
      ThemePreset? chosen;

      await tester.pumpWidget(
        wrapForTest(
          ThemePresetPicker(
            selected: ThemePreset.custom,
            onSelected: (preset) => chosen = preset,
          ),
        ),
      );

      expect(find.text('Custom'), findsOneWidget);

      // Tapping it must do nothing. Offering it as a button would raise the
      // question of what it applies, which has no answer.
      await tester.tap(find.text('Custom'));
      await tester.pump();
      expect(chosen, isNull);
    });

    testWidgets('the shipped config is shown as Default, not as Custom',
        (tester) async {
      // The end-to-end property the screen depends on: a deployment that has
      // never touched the theme should see a preset selected, not "Custom".
      expect(ThemePresets.matching(ThemeConfig.fallback), ThemePreset.aurix);

      await tester.pumpWidget(
        wrapForTest(
          ThemePresetPicker(
            selected: ThemePresets.matching(ThemeConfig.fallback),
            onSelected: (_) {},
          ),
        ),
      );

      expect(find.text('Custom'), findsNothing);
    });

    testWidgets('applying a preset repaints the app in its colours',
        (tester) async {
      // Not a check on the picker but on what tapping it produces: the whole
      // point of a preset is that the app changes, and asserting the callback
      // fired would not have caught a preset whose colours never reach a
      // palette.
      final applied = ThemePresets.apply(
        ThemeConfig.fallback,
        ThemePreset.spiderVerse,
      );

      late AurixPalette palette;
      await tester.pumpWidget(
        wrapForTest(
          Builder(
            builder: (context) {
              palette = context.palette;
              return const SizedBox.shrink();
            },
          ),
          theme: applied,
        ),
      );

      expect(palette.ground, applied.dark.background);
      expect(palette.accent, applied.dark.accent);
    });
  });
}

/// A terse way to build the font options the picker takes.
class FontOptionStub {
  const FontOptionStub(
    this.family, {
    required this.bundled,
    required this.available,
  });

  final String family;
  final bool bundled;
  final bool available;

  FontOption toOption() =>
      FontOption(family: family, bundled: bundled, available: available);
}
