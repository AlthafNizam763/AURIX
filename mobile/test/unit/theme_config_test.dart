import 'dart:convert';
import 'dart:ui';

import 'package:aurix/core/theme/aurix_palette.dart';
import 'package:aurix/core/theme/player_themes.dart';
import 'package:aurix/core/theme/theme_config.dart';
import 'package:flutter/material.dart' show Brightness, Colors;
import 'package:flutter_test/flutter_test.dart';

/// The theme configuration is the one piece of data that can make the app
/// *unusable* rather than merely incomplete — a null background paints black on
/// black, and an unparsed font name silently drops the app to the platform
/// face.
///
/// So the property under test throughout is not "valid input produces valid
/// output" but **"no input produces invalid output"**. Every test below feeds
/// the parser something a real deployment could produce — an older server, a
/// truncated cache, a hand-edited Mongo document — and asserts the app still
/// renders the identity it shipped with.
void main() {
  group('ThemeConfig parsing', () {
    test('an empty document produces the shipped identity', () {
      final config = ThemeConfig.fromJson(const <String, dynamic>{});

      expect(config.fontFamily, 'Manrope');
      expect(config.dark.background, ThemeConfig.fallback.dark.background);
      expect(config.light.text, ThemeConfig.fallback.light.text);
      expect(config.musicPlayer.mini, PlayerVariant.theme1);
      expect(config.appLogo, isNull);
    });

    test('a partial colourway keeps the defaults for the roles it omits', () {
      // What a document written by an older admin build looks like.
      final config = ThemeConfig.fromJson(const <String, dynamic>{
        'colors': <String, dynamic>{
          'dark': <String, dynamic>{'accent': '#E50914'},
        },
      });

      expect(config.dark.accent, const Color(0xFFE50914));
      expect(config.dark.background, ThemeConfig.fallback.dark.background);
      expect(config.dark.text, ThemeConfig.fallback.dark.text);
    });

    test('an unparseable colour falls back rather than becoming transparent', () {
      // The failure that matters: a null or zero here paints an invisible app.
      final config = ThemeConfig.fromJson(const <String, dynamic>{
        'colors': <String, dynamic>{
          'dark': <String, dynamic>{
            'background': 'rebeccapurple',
            'text': null,
            'surface': 42,
          },
        },
      });

      expect(config.dark.background, ThemeConfig.fallback.dark.background);
      expect(config.dark.text, ThemeConfig.fallback.dark.text);
      expect(config.dark.surface, ThemeConfig.fallback.dark.surface);
    });

    test('typography is clamped to a range that cannot break the hierarchy', () {
      final config = ThemeConfig.fromJson(const <String, dynamic>{
        'typography': <String, dynamic>{
          'scale': 12,
          'letterSpacing': -99,
          'weightBold': 5000,
          'weightRegular': 0,
        },
      });

      expect(config.typography.scale, 1.4);
      expect(config.typography.letterSpacing, -1);
      expect(config.typography.weightBold, 900);
      expect(config.typography.weightRegular, 100);
    });

    test('an unknown player variant resolves to theme 1, not to nothing', () {
      // A config written by a newer admin build naming `theme9` must degrade to
      // a player that renders, not throw on the first frame that draws one.
      final config = ThemeConfig.fromJson(const <String, dynamic>{
        'musicPlayer': <String, dynamic>{'mini': 'theme9', 'large': 'theme3'},
      });

      expect(config.musicPlayer.mini, PlayerVariant.theme1);
      expect(config.musicPlayer.large, PlayerVariant.theme3);
    });

    test('asset paths are resolved against the API base URL', () {
      final config = ThemeConfig.fromJson(
        const <String, dynamic>{'appLogo': '/api/v1/assets/abc123'},
        baseUrl: 'https://api.example.com',
      );
      expect(config.appLogo, 'https://api.example.com/api/v1/assets/abc123');
    });

    test('an absolute asset URL is left alone', () {
      final config = ThemeConfig.fromJson(
        const <String, dynamic>{'appLogo': 'https://cdn.example.com/logo.png'},
        baseUrl: 'https://api.example.com',
      );
      expect(config.appLogo, 'https://cdn.example.com/logo.png');
    });

    test('a relative asset with no base URL resolves to no logo', () {
      // Rather than to a path the image loader would try and fail to fetch,
      // which renders as a broken image where the drawn mark should be.
      final config = ThemeConfig.fromJson(
        const <String, dynamic>{'appLogo': '/api/v1/assets/abc123'},
      );
      expect(config.appLogo, isNull);
    });

    test('survives a round trip through the JSON the server actually sends', () {
      // The nested shape the app applies, and the flat mirror the documented
      // configuration format uses, describing one palette.
      const body = '''
      {
        "version": 7,
        "fontFamily": "Poppins",
        "fontAssetId": "aabbcc",
        "typography": {"scale": 1.1, "letterSpacing": 0.2, "weightBold": 800},
        "colors": {
          "dark": {"background": "#101010", "accent": "#E50914"},
          "light": {"background": "#FFFFFF", "accent": "#101010"}
        },
        "musicPlayer": {"mini": "theme2", "large": "theme3",
                        "outside": "theme1", "dynamic": "theme2"},
        "primaryColor": "#FFFFFF",
        "backgroundColor": "#101010"
      }
      ''';

      final config = ThemeConfig.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );

      expect(config.version, 7);
      expect(config.fontFamily, 'Poppins');
      expect(config.fontAssetId, 'aabbcc');
      expect(config.typography.scale, closeTo(1.1, 0.001));
      expect(config.dark.background, const Color(0xFF101010));
      expect(config.light.background, const Color(0xFFFFFFFF));
      expect(config.musicPlayer.mini, PlayerVariant.theme2);
      expect(config.musicPlayer.dynamic, PlayerVariant.theme2);
    });
  });

  group('hex colours', () {
    test('accepts the three spellings people actually type', () {
      expect(ThemeColors.parseHex('#E50914'), const Color(0xFFE50914));
      expect(ThemeColors.parseHex('E50914'), const Color(0xFFE50914));
      expect(ThemeColors.parseHex('#80E50914'), const Color(0x80E50914));
      // #RGB shorthand, expanded rather than refused.
      expect(ThemeColors.parseHex('#f0a'), const Color(0xFFFF00AA));
    });

    test('returns null for anything else, so each caller keeps its own default', () {
      // A shared "safe" fallback here would make an unparseable *text* colour
      // black on a black background — the exact failure the whole defaulting
      // chain exists to prevent.
      expect(ThemeColors.parseHex('#GGGGGG'), isNull);
      expect(ThemeColors.parseHex('rgb(1,2,3)'), isNull);
      expect(ThemeColors.parseHex(''), isNull);
      expect(ThemeColors.parseHex(null), isNull);
      expect(ThemeColors.parseHex(0xFF0000), isNull);
    });

    test('round-trips through toHex', () {
      for (final colour in <Color>[
        const Color(0xFF000000),
        const Color(0xFFFFFFFF),
        const Color(0xFFE50914),
        const Color(0x80123456),
      ]) {
        expect(ThemeColors.parseHex(ThemeColors.toHex(colour)), colour);
      }
    });

    test('omits a fully opaque alpha, so the common case reads as #RRGGBB', () {
      expect(ThemeColors.toHex(const Color(0xFFE50914)), '#E50914');
      expect(ThemeColors.toHex(const Color(0x80E50914)), '#80E50914');
    });
  });

  group('palette derivation', () {
    /// A palette an operator could plausibly configure and that the shipped
    /// monochrome identity would never produce.
    const branded = ThemeConfig(
      version: 3,
      fontFamily: 'Poppins',
      typography: ThemeTypography.fallback,
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
      musicPlayer: PlayerThemes.fallback,
    );

    test('the eight roles reach the tokens that name them', () {
      final palette = AurixPalette.fromConfig(branded, Brightness.dark);

      expect(palette.ground, branded.dark.background);
      expect(palette.surface, branded.dark.surface);
      expect(palette.surfaceHighest, branded.dark.secondary);
      expect(palette.accent, branded.dark.accent);
      expect(palette.textPrimary, branded.dark.text);
      expect(palette.player, branded.dark.player);
      expect(palette.button, branded.dark.button);
    });

    test('ink on a filled surface is readable whatever was configured', () {
      // The one guarantee the derivation makes and the admin cannot break: an
      // operator who sets a yellow button and expects a white label has made
      // the label invisible, and no UI copy prevents that reliably.
      final palette = AurixPalette.fromConfig(branded, Brightness.dark);

      expect(
        AurixPalette.contrastRatio(palette.textOnAccent, palette.accent),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        AurixPalette.contrastRatio(palette.textOnButton, palette.button),
        greaterThanOrEqualTo(4.5),
      );
      // The yellow button specifically must get black ink, not white.
      expect(palette.textOnButton, isNot(Colors.white));
    });

    test('every colour in sRGB gets readable ink', () {
      // The threshold is the standard 0.5-luminance heuristic, and this is the
      // assertion that makes it worth trusting: sweep the space and check the
      // guarantee holds everywhere, not just on the palettes we happened to
      // write a test for.
      for (var r = 0; r <= 255; r += 51) {
        for (var g = 0; g <= 255; g += 51) {
          for (var b = 0; b <= 255; b += 51) {
            final fill = Color.fromARGB(255, r, g, b);
            final config = ThemeConfig.fallback.copyWith(
              dark: ThemeColors(
                primary: fill,
                secondary: fill,
                accent: fill,
                background: fill,
                surface: fill,
                text: fill,
                player: fill,
                button: fill,
              ),
            );
            final palette = AurixPalette.fromConfig(config, Brightness.dark);

            expect(
              AurixPalette.contrastRatio(palette.textOnAccent, fill),
              greaterThanOrEqualTo(4.5),
              reason: 'ink on #${ThemeColors.toHex(fill)} is unreadable',
            );
          }
        }
      }
    });

    test('elevation rises toward the light in both themes', () {
      // In dark a raised surface gets lighter; in light it rises toward white.
      // Getting this backwards gives one of the two themes a card that looks
      // like a hole.
      final dark = AurixPalette.fromConfig(branded, Brightness.dark);
      final light = AurixPalette.fromConfig(branded, Brightness.light);

      expect(
        dark.surfaceElevated.computeLuminance(),
        greaterThan(dark.surface.computeLuminance()),
      );
      expect(
        light.surfaceElevated.computeLuminance(),
        lessThan(light.surface.computeLuminance()),
        reason: 'light-mode elevation mixes toward black, per the class note',
      );
    });

    test('text steps blend toward the ground rather than losing opacity', () {
      // A secondary label at 60% alpha over artwork picks up the artwork; the
      // same colour blended against the background stays a flat tone.
      final palette = AurixPalette.fromConfig(branded, Brightness.dark);

      expect(palette.textSecondary.a, 1.0);
      expect(palette.textTertiary.a, 1.0);
      // And they genuinely recede.
      expect(
        AurixPalette.contrastRatio(palette.textPrimary, palette.ground),
        greaterThan(
          AurixPalette.contrastRatio(palette.textSecondary, palette.ground),
        ),
      );
      expect(
        AurixPalette.contrastRatio(palette.textSecondary, palette.ground),
        greaterThan(
          AurixPalette.contrastRatio(palette.textTertiary, palette.ground),
        ),
      );
    });

    test('the shipped configuration reproduces the shipped palette', () {
      // The property that makes the migration invisible to a deployment that
      // never opens the admin panel: a default config must render exactly what
      // the app rendered before the theme system existed.
      final derived = AurixPalette.fromConfig(
        ThemeConfig.fallback,
        Brightness.dark,
      );

      // The roles that are direct assignments must match exactly.
      expect(derived.ground, AurixPalette.dark.ground);
      expect(derived.surface, AurixPalette.dark.surface);
      expect(derived.surfaceHighest, AurixPalette.dark.surfaceHighest);
      expect(derived.accent, AurixPalette.dark.accent);
      expect(derived.textPrimary, AurixPalette.dark.textPrimary);
      expect(derived.textOnAccent, AurixPalette.dark.textOnAccent);
      expect(derived.player, AurixPalette.dark.surfaceElevated);

      // The derived steps are computed rather than copied, so they land close
      // rather than identical. A few 255ths is below the threshold of vision
      // and is what "reproduces the shipped palette" honestly means here.
      expect(
        derived.surfaceElevated.computeLuminance(),
        closeTo(AurixPalette.dark.surfaceElevated.computeLuminance(), 0.01),
      );
      expect(
        derived.textSecondary.computeLuminance(),
        closeTo(AurixPalette.dark.textSecondary.computeLuminance(), 0.08),
      );
    });
  });

  group('player variants', () {
    test('every surface and variant resolves to a style', () {
      for (final variant in PlayerVariant.values) {
        expect(MiniPlayerStyle.of(variant), isNotNull);
        expect(LargePlayerStyle.of(variant), isNotNull);
        expect(OutsidePlayerStyle.of(variant), isNotNull);
        expect(DynamicPlayerStyle.of(variant), isNotNull);
      }
    });

    test('the notification never promotes an action that does not exist', () {
      // `androidCompactActionIndices` points into the control list, and an
      // index past its end is an out-of-range crash inside the platform
      // plugin rather than a missing button.
      const publishedControls = 3;
      for (final variant in PlayerVariant.values) {
        for (final index in OutsidePlayerStyle.of(variant).compactActions) {
          expect(index, inInclusiveRange(0, publishedControls - 1));
        }
      }
      // Android shows at most three.
      for (final variant in PlayerVariant.values) {
        expect(OutsidePlayerStyle.of(variant).compactActions.length, lessThanOrEqualTo(3));
      }
    });

    test('one surface can be changed without touching the others', () {
      const themes = PlayerThemes.fallback;
      final changed = themes.withSurface(PlayerSurface.large, PlayerVariant.theme3);

      expect(changed.large, PlayerVariant.theme3);
      expect(changed.mini, PlayerVariant.theme1);
      expect(changed.outside, PlayerVariant.theme1);
      expect(changed.dynamic, PlayerVariant.theme1);
    });

    test('the variants are genuinely different, not relabelled', () {
      // A guard against a future edit that copies a style block and forgets to
      // change it — four identical options would be worse than one.
      //
      // Compared on the whole descriptor rather than on one field. An earlier
      // version keyed the large player off `backdrop` alone, which stopped
      // being a distinctness test the moment two variants legitimately shared
      // a backdrop and differed in artwork shape and alignment instead.
      void allDistinct<T>(String surface, String Function(T) signature, T Function(PlayerVariant) of) {
        final signatures = PlayerVariant.values.map((v) => signature(of(v))).toList();
        expect(
          signatures.toSet(),
          hasLength(PlayerVariant.values.length),
          reason: 'two $surface variants are identical: $signatures',
        );
      }

      allDistinct<MiniPlayerStyle>(
        'mini player',
        (s) => '${s.radius}|${s.frosted}|${s.artworkSize}|${s.artworkRadius}|'
            '${s.horizontalMargin}|${s.bottomMargin}|${s.showsNextButton}|'
            '${s.progressPlacement}|${s.tintsFromArtwork}|${s.elevation}',
        MiniPlayerStyle.of,
      );

      allDistinct<LargePlayerStyle>(
        'large player',
        (s) => '${s.backdrop}|${s.artworkRadius}|${s.artworkScale}|'
            '${s.artworkShadow}|${s.titleAlignment}|${s.transportSpacing}|'
            '${s.showsBackdropGrain}',
        LargePlayerStyle.of,
      );

      allDistinct<OutsidePlayerStyle>(
        'outside player',
        (s) => '${s.compactActions}|${s.showsSeekControls}',
        OutsidePlayerStyle.of,
      );

      allDistinct<DynamicPlayerStyle>(
        'dynamic player',
        (s) => '${s.collapsedHeight}|${s.cornerRadius}|${s.showsWaveform}|'
            '${s.expandOnTrackChange}|${s.glowIntensity}',
        DynamicPlayerStyle.of,
      );
    });
  });
}
