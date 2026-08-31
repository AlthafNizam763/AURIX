import 'package:flutter/material.dart';

import 'theme_config.dart';

/// The named colourways the Appearance screen offers before an admin starts
/// mixing their own.
///
/// ## Why presets exist at all
///
/// The colour editor is eight pickers across two brightnesses — sixteen
/// decisions — and every one of them can produce something unreadable. That is
/// the right amount of power for a deployment that wants a specific brand, and
/// far too much for the far commoner case of "make it darker" or "make it
/// red". A preset collapses those sixteen decisions into one tap that is known
/// to be legible, and leaves the pickers underneath for anyone who wants them.
///
/// So a preset is not a *mode*. Applying one writes its colours into the
/// config and nothing else happens; the pickers keep working, and the moment
/// one of them is moved the selection reads as [ThemePreset.custom] again.
/// There is no stored "which preset" field, and deliberately so — see
/// [ThemePresets.matching].
///
/// ## Why the selection is derived rather than stored
///
/// A stored preset id is a second source of truth about the colours, and the
/// two drift the first time anything writes colours without going through the
/// picker: a server-side edit, a config restored from a backup, or a version of
/// the app that predates the preset it names. The result is a screen that says
/// "Midnight" while showing something else, which is worse than saying nothing.
///
/// Deriving it from the colours themselves cannot drift, costs one comparison
/// of eight values, and means the wire format did not have to change to gain
/// this feature — a config written by the old admin panel still lights up the
/// right radio button.
///
/// ## Contrast
///
/// Every preset below is asserted against WCAG AA in
/// `test/unit/theme_presets_test.dart` for both colourways: body text on
/// background, text on surface, and text on the player. A preset is the one
/// path where the admin does not see the individual colours before applying
/// them, so shipping one that fails contrast would be handing someone an
/// unreadable app in a single tap.
enum ThemePreset {
  /// What AURIX ships with: monochrome, no hue anywhere.
  aurix('Default', 'The AURIX identity — monochrome, no hue anywhere.'),

  /// Loud magenta and cyan against near-black.
  spiderVerse('Spider-Verse', 'Halftone magenta and cyan on ink.'),

  /// Deep blue, the way a night-mode reader is blue.
  midnight('Midnight', 'Cool navy, softened. Easy at 2am.'),

  /// True black, for OLED panels where black costs no light.
  amoled('AMOLED', 'True black. Pixels that are off, on an OLED panel.'),

  /// Not a preset — what the picker shows when the colours match none of them.
  custom('Custom', 'Your own colours, mixed below.');

  const ThemePreset(this.label, this.description);

  /// The name on the radio button.
  final String label;

  /// One line under it, saying what it looks like.
  final String description;

  /// True for the entry that cannot be *applied*, only arrived at.
  bool get isCustom => this == ThemePreset.custom;
}

/// The colours behind each [ThemePreset].
abstract final class ThemePresets {
  /// Every preset a user can actually pick, in the order they are shown.
  ///
  /// [ThemePreset.custom] is absent: it is a state the pickers put the config
  /// into, not a thing to choose. The Appearance screen renders it as a
  /// trailing, unselectable row when it is the current selection.
  static const List<ThemePreset> selectable = <ThemePreset>[
    ThemePreset.aurix,
    ThemePreset.spiderVerse,
    ThemePreset.midnight,
    ThemePreset.amoled,
  ];

  /// The dark colourway for [preset], or null for [ThemePreset.custom].
  static ThemeColors? dark(ThemePreset preset) => switch (preset) {
    ThemePreset.aurix => ThemeConfig.fallback.dark,
    ThemePreset.spiderVerse => _spiderVerseDark,
    ThemePreset.midnight => _midnightDark,
    ThemePreset.amoled => _amoledDark,
    ThemePreset.custom => null,
  };

  /// The light colourway for [preset], or null for [ThemePreset.custom].
  static ThemeColors? light(ThemePreset preset) => switch (preset) {
    ThemePreset.aurix => ThemeConfig.fallback.light,
    ThemePreset.spiderVerse => _spiderVerseLight,
    ThemePreset.midnight => _midnightLight,
    ThemePreset.amoled => _amoledLight,
    ThemePreset.custom => null,
  };

  /// Applies [preset] to [config], writing *both* colourways.
  ///
  /// Both, always. AURIX follows the device's light/dark setting unless the
  /// user has overridden it, so writing only the one being edited would leave
  /// a deployment whose users are half on light mode looking at a preset
  /// applied to nobody. The Appearance screen's brightness toggle chooses which
  /// half you are *previewing*, not which half a preset writes.
  ///
  /// Everything that is not a colour — font, type scale, player designs, logo
  /// — is left alone. A preset is a colourway, and someone who picked Poppins
  /// and then tried Midnight has not asked to lose Poppins.
  static ThemeConfig apply(ThemeConfig config, ThemePreset preset) {
    final darkColors = dark(preset);
    final lightColors = light(preset);
    if (darkColors == null || lightColors == null) return config;
    return config.copyWith(dark: darkColors, light: lightColors);
  }

  /// Which preset [config] currently *is*, or [ThemePreset.custom].
  ///
  /// Both colourways must match. A config that is Midnight in the dark and
  /// something hand-mixed in the light is not Midnight — saying it was would
  /// mean a later tap on "Midnight" silently discarded the light edits without
  /// the button appearing to do anything.
  static ThemePreset matching(ThemeConfig config) {
    for (final preset in selectable) {
      if (dark(preset) == config.dark && light(preset) == config.light) return preset;
    }
    return ThemePreset.custom;
  }

  // -------------------------------------------------------------------------
  // Spider-Verse
  // -------------------------------------------------------------------------
  //
  // The comic-halftone palette the app's intro animation once used. Magenta is
  // the accent and the button; cyan is `primary`, which paints headings and
  // the active tab, so the two never sit on each other.

  static const ThemeColors _spiderVerseDark = ThemeColors(
    primary: Color(0xFF3BE8F5),
    secondary: Color(0xFF241A2E),
    accent: Color(0xFFFF2D95),
    background: Color(0xFF0B0714),
    surface: Color(0xFF160F20),
    text: Color(0xFFF6F2FF),
    player: Color(0xFF1D1429),
    button: Color(0xFFFF2D95),
  );

  static const ThemeColors _spiderVerseLight = ThemeColors(
    primary: Color(0xFF0A6B78),
    secondary: Color(0xFFF0E7FA),
    // Darker than the dark colourway's magenta: the same pink that reads as
    // neon on ink is illegible as a button fill on white.
    accent: Color(0xFFC2005F),
    background: Color(0xFFFBF7FF),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF160F20),
    player: Color(0xFFFFFFFF),
    button: Color(0xFFC2005F),
  );

  // -------------------------------------------------------------------------
  // Midnight
  // -------------------------------------------------------------------------
  //
  // Navy rather than grey, and desaturated rather than vivid. The accent is a
  // pale ice blue instead of a saturated one so that it can carry dark text as
  // a filled button without a third colour being introduced for the label.

  static const ThemeColors _midnightDark = ThemeColors(
    primary: Color(0xFFE6EDFF),
    secondary: Color(0xFF1B2440),
    accent: Color(0xFF7FA8FF),
    background: Color(0xFF070B18),
    surface: Color(0xFF111827),
    text: Color(0xFFE6EDFF),
    player: Color(0xFF16203A),
    button: Color(0xFF7FA8FF),
  );

  static const ThemeColors _midnightLight = ThemeColors(
    primary: Color(0xFF14213D),
    secondary: Color(0xFFE3E9F7),
    accent: Color(0xFF1D4ED8),
    background: Color(0xFFF4F6FC),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF14213D),
    player: Color(0xFFFFFFFF),
    button: Color(0xFF1D4ED8),
  );

  // -------------------------------------------------------------------------
  // AMOLED
  // -------------------------------------------------------------------------
  //
  // `background` is `#000000` exactly, which is the entire point: on an OLED
  // panel a black pixel is an unlit pixel, so this is the one preset that
  // changes battery life rather than only taste. `surface` and `player` are
  // lifted just enough to separate a card from the ground — going full black
  // there too would erase every boundary in the app.

  static const ThemeColors _amoledDark = ThemeColors(
    primary: Color(0xFFFFFFFF),
    secondary: Color(0xFF1A1A1A),
    accent: Color(0xFFFFFFFF),
    background: Color(0xFF000000),
    surface: Color(0xFF0C0C0C),
    text: Color(0xFFFFFFFF),
    player: Color(0xFF121212),
    button: Color(0xFFFFFFFF),
  );

  /// AMOLED has no light counterpart of its own — an unlit pixel is a dark-mode
  /// idea — so its light colourway is the shipped one. Stated here rather than
  /// left implicit, because [matching] compares both and a copy that drifted
  /// from [ThemeConfig.fallback] would stop AMOLED being recognisable.
  static const ThemeColors _amoledLight = ThemeColors(
    primary: Color(0xFF0A0A0A),
    secondary: Color(0xFFFFFFFF),
    accent: Color(0xFF0A0A0A),
    background: Color(0xFFF2F2F2),
    surface: Color(0xFFFAFAFA),
    text: Color(0xFF0A0A0A),
    player: Color(0xFFFFFFFF),
    button: Color(0xFF0A0A0A),
  );
}
