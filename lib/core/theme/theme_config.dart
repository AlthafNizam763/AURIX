import 'dart:ui' show Color;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/material.dart' show Brightness;

import 'app_colors.dart';

/// The application's appearance, as configuration rather than as code.
///
/// ## What this replaced
///
/// Every colour, the type scale and the player layouts used to be compile-time
/// constants in `AppColors`, `AppTypography` and the player widgets. Changing
/// any of them meant editing Dart and shipping a build.
///
/// They are now one document in MongoDB, fetched on launch and applied to the
/// whole widget tree through `ThemeData`. The constants did not go away — they
/// are [ThemeConfig.fallback], which is what the app renders with when there is
/// no server, no network and no cache. That is deliberate and load-bearing: an
/// app whose appearance depends on a network call is an app with a blank first
/// frame, and an unreadable theme document must never be able to make it
/// unusable.
///
/// ## The three layers of defaulting
///
/// A missing value is filled in three times over, and the redundancy is the
/// point rather than an oversight:
///
///  1. **The server** normalises on write *and* on read, so the stored document
///     is always complete.
///  2. **[ThemeConfig.fromJson]** defaults every field again, so a response
///     from an older API — or a cached copy written by an older build — cannot
///     produce a null.
///  3. **[fallback]** is what is used when there is no configuration at all.
///
/// Any one of these failing leaves the other two, and the failure mode of the
/// whole chain is "the app looks like it shipped", not "the app is black on
/// black".
@immutable
class ThemeConfig extends Equatable {
  const ThemeConfig({
    required this.version,
    required this.fontFamily,
    required this.typography,
    required this.dark,
    required this.light,
    required this.musicPlayer,
    this.fontAssetId,
    this.appLogo,
    this.appIcon,
  });

  /// Bumped by the server on every write.
  ///
  /// The cache key, and the reason the app can render from a cached config on
  /// the first frame and reconcile afterwards: comparing two integers is how
  /// the controller decides whether the whole widget tree needs rebuilding,
  /// rather than deep-comparing two config objects.
  final int version;

  /// The family name every text style resolves to.
  ///
  /// A *name*, not a file. Whether it resolves to a bundled asset, a font
  /// downloaded from the API, or the platform default is [FontRegistry]'s
  /// problem — see there for why an unavailable family degrades to the previous
  /// face rather than to a fallback that changes every metric on screen.
  final String fontFamily;

  /// The uploaded font file backing [fontFamily], when there is one.
  final String? fontAssetId;

  final ThemeTypography typography;

  /// The two colourways.
  ///
  /// Both are stored, because AURIX follows the device's light/dark setting
  /// unless the user overrides it. A configuration that carried only one would
  /// leave the other unstyled — which on a light phone means white text on
  /// white.
  final ThemeColors dark;
  final ThemeColors light;

  /// An absolute URL, already resolved against the API base — see
  /// [ThemeConfig.fromJson]. Null means "draw the built-in mark".
  final String? appLogo;
  final String? appIcon;

  final PlayerThemes musicPlayer;

  ThemeColors colorsFor(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// The AURIX identity as shipped.
  ///
  /// Mirrors `AurixPalette.dark` / `.light` exactly, so a build with no server
  /// renders pixel-for-pixel what the app shipped with. The server holds the
  /// same values in `DEFAULT_THEME`; the duplication is intentional, because
  /// this copy has to work when the server cannot be reached at all.
  static const ThemeConfig fallback = ThemeConfig(
    version: 0,
    fontFamily: 'Manrope',
    typography: ThemeTypography.fallback,
    // Each value is the token `AurixPalette.dark`/`.light` already held, so a
    // deployment that never opens the admin panel renders exactly what the app
    // rendered before the theme system existed. `theme_config_test.dart`
    // asserts that, which is what stops these drifting.
    dark: ThemeColors(
      primary: AppColors.textPrimary,
      // The top surface step — chips, the highest card — which is what the
      // admin panel's description of this role says it paints.
      secondary: AppColors.surfaceHighest,
      accent: AppColors.accent,
      background: AppColors.background,
      surface: AppColors.surface,
      text: AppColors.textPrimary,
      // The tone the mini player was already drawn in, so switching to the
      // configured palette does not move it.
      player: AppColors.surfaceElevated,
      button: AppColors.accent,
    ),
    light: ThemeColors(
      primary: Color(0xFF0A0A0A),
      secondary: AppColors.white,
      accent: Color(0xFF0A0A0A),
      background: Color(0xFFF2F2F2),
      surface: Color(0xFFFAFAFA),
      text: Color(0xFF0A0A0A),
      player: AppColors.white,
      button: Color(0xFF0A0A0A),
    ),
    musicPlayer: PlayerThemes.fallback,
  );

  /// Parses the API's response.
  ///
  /// [baseUrl] resolves the relative asset paths the server returns
  /// (`/api/v1/assets/…`) into absolute URLs. Doing it here rather than at each
  /// render site means no widget has to know the API's address to draw a logo,
  /// and a config that has been cached to disk stays valid if the base URL
  /// changes — because the cache stores the raw response, not the resolved one.
  factory ThemeConfig.fromJson(Map<String, dynamic> json, {String baseUrl = ''}) {
    String? asset(Object? value) {
      if (value is! String || value.isEmpty) return null;
      if (value.startsWith('http://') || value.startsWith('https://')) return value;
      if (baseUrl.isEmpty) return null;
      return '$baseUrl$value';
    }

    final colors = json['colors'];
    final colorsMap = colors is Map<String, dynamic> ? colors : const <String, dynamic>{};

    return ThemeConfig(
      version: (json['version'] as num?)?.toInt() ?? fallback.version,
      fontFamily: _string(json['fontFamily']) ?? fallback.fontFamily,
      fontAssetId: _string(json['fontAssetId']),
      typography: ThemeTypography.fromJson(json['typography']),
      dark: ThemeColors.fromJson(colorsMap['dark'], fallback.dark),
      light: ThemeColors.fromJson(colorsMap['light'], fallback.light),
      appLogo: asset(json['appLogo']),
      appIcon: asset(json['appIcon']),
      musicPlayer: PlayerThemes.fromJson(json['musicPlayer']),
    );
  }

  static String? _string(Object? value) =>
      value is String && value.trim().isNotEmpty ? value.trim() : null;

  ThemeConfig copyWith({
    int? version,
    String? fontFamily,
    String? fontAssetId,
    ThemeTypography? typography,
    ThemeColors? dark,
    ThemeColors? light,
    String? appLogo,
    String? appIcon,
    PlayerThemes? musicPlayer,
  }) => ThemeConfig(
    version: version ?? this.version,
    fontFamily: fontFamily ?? this.fontFamily,
    fontAssetId: fontAssetId ?? this.fontAssetId,
    typography: typography ?? this.typography,
    dark: dark ?? this.dark,
    light: light ?? this.light,
    appLogo: appLogo ?? this.appLogo,
    appIcon: appIcon ?? this.appIcon,
    musicPlayer: musicPlayer ?? this.musicPlayer,
  );

  @override
  List<Object?> get props => [
    version,
    fontFamily,
    fontAssetId,
    typography,
    dark,
    light,
    appLogo,
    appIcon,
    musicPlayer,
  ];
}

/// The eight colour roles an administrator can set.
///
/// Roles, not slots. Each one names *what it paints* rather than where it sits
/// in Material's `ColorScheme` — the mapping onto that is `AppTheme`'s job, and
/// it is deliberately not one-to-one. See the note there on why `secondary` is
/// routed to a surface rather than to an accent.
@immutable
class ThemeColors extends Equatable {
  const ThemeColors({
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.background,
    required this.surface,
    required this.text,
    required this.player,
    required this.button,
  });

  /// Headings, active tabs and the brand mark.
  final Color primary;

  /// Chips, dividers and the second surface layer.
  final Color secondary;

  /// The one thing to press: play buttons, focus rings, filled controls.
  final Color accent;

  /// The page itself.
  final Color background;

  /// Cards, sheets and list rows.
  final Color surface;

  /// Body and title text.
  final Color text;

  /// The mini player and the full player background.
  ///
  /// Its own role rather than an alias for [surface], because the player is the
  /// one surface that is expected to differ from the rest of the app — that is
  /// the whole premise of a separate player theme.
  final Color player;

  /// Filled button fill. Separate from [accent] so a design can have a loud
  /// play button and quiet buttons, or the reverse.
  final Color button;

  factory ThemeColors.fromJson(Object? json, ThemeColors fallback) {
    if (json is! Map) return fallback;

    Color read(String key, Color fallbackColor) =>
        parseHex(json[key]) ?? fallbackColor;

    return ThemeColors(
      primary: read('primary', fallback.primary),
      secondary: read('secondary', fallback.secondary),
      accent: read('accent', fallback.accent),
      background: read('background', fallback.background),
      surface: read('surface', fallback.surface),
      text: read('text', fallback.text),
      player: read('player', fallback.player),
      button: read('button', fallback.button),
    );
  }

  Map<String, String> toJson() => <String, String>{
    'primary': toHex(primary),
    'secondary': toHex(secondary),
    'accent': toHex(accent),
    'background': toHex(background),
    'surface': toHex(surface),
    'text': toHex(text),
    'player': toHex(player),
    'button': toHex(button),
  };

  /// `#RRGGBB` or `#AARRGGBB`, or null when the value is not a colour.
  ///
  /// Returning null rather than a "safe" black is what lets every caller fall
  /// back to *its own* default. A single hard-coded fallback here would make an
  /// unparseable text colour black on a black background, which is exactly the
  /// failure this whole defaulting chain exists to prevent.
  static Color? parseHex(Object? value) {
    if (value is! String) return null;

    var hex = value.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 3) {
      // `#f0a`, which is what people type. Expanded rather than refused.
      hex = hex.split('').map((c) => '$c$c').join();
    }
    if (hex.length == 6) hex = 'FF$hex';
    if (hex.length != 8) return null;

    final parsed = int.tryParse(hex, radix: 16);
    return parsed == null ? null : Color(parsed);
  }

  static String toHex(Color color) {
    // `toARGB32` rather than the deprecated `.value`: the channels are doubles
    // in the wide-gamut colour model, and this is the documented way to get the
    // 32-bit sRGB integer back out.
    final argb = color.toARGB32();
    final alpha = (argb >> 24) & 0xFF;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();
    return alpha == 0xFF
        ? '#$rgb'
        : '#${alpha.toRadixString(16).padLeft(2, '0').toUpperCase()}$rgb';
  }

  @override
  List<Object?> get props =>
      [primary, secondary, accent, background, surface, text, player, button];
}

/// Global typography settings.
///
/// A *multiplier* on the shipped scale rather than a set of absolute sizes, and
/// that constraint is the design decision worth defending: the proportions
/// between display, title and body are what make the hierarchy legible, and an
/// admin given fifteen independent point sizes can — and eventually will —
/// flatten them into an unreadable wall. One scale factor cannot.
@immutable
class ThemeTypography extends Equatable {
  const ThemeTypography({
    required this.scale,
    required this.letterSpacing,
    required this.weightRegular,
    required this.weightMedium,
    required this.weightBold,
    required this.weightDisplay,
  });

  /// Multiplies every font size. Clamped to 0.8–1.4 by the server.
  final double scale;

  /// Added to every style's tracking, in logical pixels.
  final double letterSpacing;

  final int weightRegular;
  final int weightMedium;
  final int weightBold;
  final int weightDisplay;

  static const ThemeTypography fallback = ThemeTypography(
    scale: 1,
    letterSpacing: 0,
    // The shipped Manrope scale. `AppTypography` sets these on the `wght` axis
    // as well as through `fontWeight`; see the note there.
    weightRegular: 400,
    weightMedium: 600,
    weightBold: 700,
    weightDisplay: 800,
  );

  factory ThemeTypography.fromJson(Object? json) {
    if (json is! Map) return fallback;

    double number(String key, double fallbackValue, double min, double max) {
      final raw = json[key];
      final value = raw is num ? raw.toDouble() : double.tryParse('$raw');
      if (value == null || !value.isFinite) return fallbackValue;
      return value.clamp(min, max);
    }

    int weight(String key, int fallbackValue) =>
        number(key, fallbackValue.toDouble(), 100, 900).round();

    return ThemeTypography(
      scale: number('scale', fallback.scale, 0.8, 1.4),
      letterSpacing: number('letterSpacing', fallback.letterSpacing, -1, 2),
      weightRegular: weight('weightRegular', fallback.weightRegular),
      weightMedium: weight('weightMedium', fallback.weightMedium),
      weightBold: weight('weightBold', fallback.weightBold),
      weightDisplay: weight('weightDisplay', fallback.weightDisplay),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'scale': scale,
    'letterSpacing': letterSpacing,
    'weightRegular': weightRegular,
    'weightMedium': weightMedium,
    'weightBold': weightBold,
    'weightDisplay': weightDisplay,
  };

  ThemeTypography copyWith({
    double? scale,
    double? letterSpacing,
    int? weightRegular,
    int? weightMedium,
    int? weightBold,
    int? weightDisplay,
  }) => ThemeTypography(
    scale: scale ?? this.scale,
    letterSpacing: letterSpacing ?? this.letterSpacing,
    weightRegular: weightRegular ?? this.weightRegular,
    weightMedium: weightMedium ?? this.weightMedium,
    weightBold: weightBold ?? this.weightBold,
    weightDisplay: weightDisplay ?? this.weightDisplay,
  );

  @override
  List<Object?> get props => [
    scale,
    letterSpacing,
    weightRegular,
    weightMedium,
    weightBold,
    weightDisplay,
  ];
}

/// Which design each player surface uses.
///
/// The four surfaces are genuinely different components rather than one
/// component at four sizes, which is why each picks its variant independently:
/// the mini player is a bar above the tabs, the large player is a full screen,
/// the outside player is the OS notification, and the dynamic player is the
/// floating island. A single "player theme" setting would have to mean four
/// different things at once.
@immutable
class PlayerThemes extends Equatable {
  const PlayerThemes({
    required this.mini,
    required this.large,
    required this.outside,
    required this.dynamic,
  });

  final PlayerVariant mini;
  final PlayerVariant large;
  final PlayerVariant outside;
  final PlayerVariant dynamic;

  static const PlayerThemes fallback = PlayerThemes(
    mini: PlayerVariant.theme1,
    large: PlayerVariant.theme1,
    outside: PlayerVariant.theme1,
    dynamic: PlayerVariant.theme1,
  );

  factory PlayerThemes.fromJson(Object? json) {
    if (json is! Map) return fallback;
    return PlayerThemes(
      mini: PlayerVariant.parse(json['mini']),
      large: PlayerVariant.parse(json['large']),
      outside: PlayerVariant.parse(json['outside']),
      dynamic: PlayerVariant.parse(json['dynamic']),
    );
  }

  Map<String, String> toJson() => <String, String>{
    'mini': mini.wireValue,
    'large': large.wireValue,
    'outside': outside.wireValue,
    'dynamic': dynamic.wireValue,
  };

  PlayerVariant forSurface(PlayerSurface surface) => switch (surface) {
    PlayerSurface.mini => mini,
    PlayerSurface.large => large,
    PlayerSurface.outside => outside,
    PlayerSurface.dynamic => dynamic,
  };

  PlayerThemes withSurface(PlayerSurface surface, PlayerVariant variant) =>
      switch (surface) {
        PlayerSurface.mini => PlayerThemes(
          mini: variant,
          large: large,
          outside: outside,
          dynamic: dynamic,
        ),
        PlayerSurface.large => PlayerThemes(
          mini: mini,
          large: variant,
          outside: outside,
          dynamic: dynamic,
        ),
        PlayerSurface.outside => PlayerThemes(
          mini: mini,
          large: large,
          outside: variant,
          dynamic: dynamic,
        ),
        PlayerSurface.dynamic => PlayerThemes(
          mini: mini,
          large: large,
          outside: outside,
          dynamic: variant,
        ),
      };

  @override
  List<Object?> get props => [mini, large, outside, dynamic];
}

/// The four configurable player surfaces.
enum PlayerSurface {
  mini('Mini player', 'The bar above the tabs while something is playing.'),
  large('Large player', 'The full-screen player.'),
  outside('Outside player', 'The notification and lock-screen surface.'),
  dynamic('Dynamic player', 'The floating Dynamic Island pill.');

  const PlayerSurface(this.label, this.description);
  final String label;
  final String description;

  String get wireValue => name;
}

/// The designs each surface can take.
///
/// Four per surface. Deliberately an enum rather than a free string: a variant
/// name the app has no widget for would render nothing at all, and a compile
/// error is a better place to discover a fifth design than a blank player.
///
/// Adding one is three edits and no new files — a constant on each of the four
/// style classes in `player_themes.dart`, a case in each `of()`, and an entry
/// in the server's `PLAYER_VARIANTS`. The exhaustive switches are what make the
/// compiler list the places, which is the whole reason they are not defaulted.
enum PlayerVariant {
  /// The AURIX default — the design the app shipped with.
  theme1('Theme 1'),

  /// A rounded, floating treatment.
  theme2('Theme 2'),

  /// An expressive, artwork-led treatment.
  theme3('Theme 3'),

  /// A restrained, squared-off treatment: the least chrome of the four, and
  /// the cheapest to draw — no blur pass on the mini bar, no waveform on the
  /// island. An operator running on low-end hardware gets a faster app by
  /// choosing it, which is why "quiet" is a real design and not a filler.
  theme4('Theme 4');

  const PlayerVariant(this.label);
  final String label;

  String get wireValue => name;

  /// Unknown values resolve to [theme1] rather than throwing.
  ///
  /// A config written by a newer admin build naming `theme5` must degrade to a
  /// player that works, not to an exception on the first frame that draws one.
  static PlayerVariant parse(Object? value) => switch (value) {
    'theme2' => theme2,
    'theme3' => theme3,
    'theme4' => theme4,
    _ => theme1,
  };
}
