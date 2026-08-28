import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_typography.dart';
import 'aurix_palette.dart';
import 'font_registry.dart';
import 'theme_config.dart';

/// Centralised [ThemeData] for AURIX.
///
/// Dark is the primary and default experience; light is a designed counterpart
/// rather than an inversion — see [AurixPalette]. Both resolve every colour
/// from the same [AurixPalette] instance, which is attached to the result as a
/// theme extension so widgets can read tokens the [ColorScheme] has no slot for.
///
/// ## Monochrome and Material
///
/// Material's `ColorScheme` assumes a hue-bearing brand: `primary`, `secondary`
/// and `tertiary` exist so components can differentiate themselves by colour.
/// AURIX has exactly one accent and it is white, so the mapping below collapses
/// that structure deliberately:
///
///  * `primary` is the accent. It is the only slot that reads as "press this".
///  * `secondary` and `tertiary` are routed to **surfaces**, not to the accent.
///    Material sends them to chips, FABs and a scattering of component
///    accents; pointing them at white would make every chip on screen shout as
///    loudly as the play button. Pointing them at graphite is what keeps the
///    accent scarce, which is the entire basis of the hierarchy.
abstract final class AppTheme {
  /// The shipped dark theme. Used before any configuration is available — the
  /// very first frame, a widget test, a build with no server.
  static ThemeData dark() => _build(AurixPalette.dark, AppTypography.textTheme);

  static ThemeData light() => _build(
    AurixPalette.light,
    AppTypography.textTheme.apply(
      bodyColor: AurixPalette.light.textPrimary,
      displayColor: AurixPalette.light.textPrimary,
    ),
  );

  /// The configured theme.
  ///
  /// The single point at which a MongoDB document becomes a [ThemeData]. Every
  /// colour, size and weight below resolves from [config]; nothing downstream
  /// of here reads configuration, which is the property that makes the theme
  /// system reusable rather than a set of lookups scattered through the widget
  /// tree.
  ///
  /// [fontFamily] is passed separately from `config.fontFamily` on purpose: it
  /// is the family that is actually *registered and renderable right now*, which
  /// differs while a custom font is still downloading. See [FontRegistry] and
  /// [ThemeState.fontFamily].
  static ThemeData from(
    ThemeConfig config,
    Brightness brightness, {
    required String fontFamily,
  }) {
    final palette = AurixPalette.fromConfig(config, brightness);

    return _build(
      palette,
      AppTypography.themeFor(
        fontFamily: fontFamily,
        typography: config.typography,
        bodyColor: palette.textPrimary,
        mutedColor: palette.textSecondary,
      ),
      fontFamily: fontFamily,
    );
  }

  /// The system UI overlay for a configured palette.
  ///
  /// Not a constant any more, and it cannot be: the navigation bar is painted
  /// with the configured background, and a black bar under a white app is the
  /// kind of mismatch that reads as a rendering bug. The icon brightness is
  /// derived from the background's luminance rather than from the theme's
  /// nominal brightness, so a "dark" theme configured with a pale background
  /// still gets dark icons.
  static SystemUiOverlayStyle overlayFrom(
    ThemeConfig config,
    Brightness brightness,
  ) {
    final colors = config.colorsFor(brightness);
    final isLightSurface = colors.background.computeLuminance() > 0.5;

    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isLightSurface ? Brightness.dark : Brightness.light,
      statusBarBrightness: isLightSurface ? Brightness.light : Brightness.dark,
      systemNavigationBarColor: colors.background,
      systemNavigationBarIconBrightness:
          isLightSurface ? Brightness.dark : Brightness.light,
      systemNavigationBarDividerColor: Colors.transparent,
    );
  }

  /// System UI overlay for the dark theme: light icons on a transparent bar, so
  /// headers can bleed under the status bar.
  static const SystemUiOverlayStyle darkOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    statusBarBrightness: Brightness.dark,
    systemNavigationBarColor: AppColors.background,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarDividerColor: Colors.transparent,
  );

  static const SystemUiOverlayStyle lightOverlay = SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    statusBarBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFFF2F2F2),
    systemNavigationBarIconBrightness: Brightness.dark,
    systemNavigationBarDividerColor: Colors.transparent,
  );

  static SystemUiOverlayStyle overlayFor(Brightness brightness) =>
      brightness == Brightness.dark ? darkOverlay : lightOverlay;

  static ThemeData _build(
    AurixPalette palette,
    TextTheme textTheme, {
    String fontFamily = FontRegistry.fallbackFamily,
  }) {
    final brightness = palette.brightness;
    final isDark = palette.isDark;

    final colorScheme = ColorScheme(
      brightness: brightness,
      primary: palette.accent,
      onPrimary: palette.textOnAccent,
      primaryContainer: palette.surfaceHighest,
      onPrimaryContainer: palette.textPrimary,

      // Surfaces, not the accent — see the class note.
      secondary: palette.surfaceHighest,
      onSecondary: palette.textPrimary,
      secondaryContainer: palette.surfaceElevated,
      onSecondaryContainer: palette.textPrimary,

      tertiary: palette.textSecondary,
      onTertiary: palette.ground,
      tertiaryContainer: palette.surfaceElevated,
      onTertiaryContainer: palette.textPrimary,

      // Monochrome has no alarm hue. Error resolves to the accent and is always
      // paired with a glyph and a sentence at the call site — colour is never
      // the only signal. Routing it here (rather than to a red) keeps the
      // contrast guarantee: whatever `error` is, `onError` is its opposite end.
      error: palette.accent,
      onError: palette.textOnAccent,
      errorContainer: palette.surfaceHighest,
      onErrorContainer: palette.textPrimary,

      surface: palette.surface,
      onSurface: palette.textPrimary,
      surfaceContainerLowest: palette.ground,
      surfaceContainerLow: palette.surface,
      surfaceContainer: palette.surfaceElevated,
      surfaceContainerHigh: palette.surfaceHighest,
      surfaceContainerHighest: palette.surfaceHighest,
      onSurfaceVariant: palette.textSecondary,
      // Derived from the configured text colour rather than fixed greys.
      // Hard-coded outlines survived the monochrome redesign because every
      // palette was grey; against a configured background they are the one
      // thing that would still look like the old theme.
      outline: Color.alphaBlend(
        palette.textPrimary.withValues(alpha: 0.22),
        palette.ground,
      ),
      outlineVariant: Color.alphaBlend(
        palette.textPrimary.withValues(alpha: 0.10),
        palette.ground,
      ),
      shadow: Colors.black,
      scrim: AppColors.scrim,
      inverseSurface: palette.textPrimary,
      onInverseSurface: palette.ground,
      inversePrimary: palette.accentPressed,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: colorScheme,
      // The tokens Material has no slot for — glass, grain, shimmer, the
      // surface stack — travel on the theme so widgets read them from context.
      // Without this, `context.palette` silently falls back to dark and the
      // light theme renders white text on white.
      extensions: <ThemeExtension<dynamic>>[palette],
      scaffoldBackgroundColor: palette.ground,
      canvasColor: palette.ground,
      fontFamily: fontFamily,
      textTheme: textTheme,
      // InkSparkle throws a coloured, animated splash across artwork. AURIX
      // draws its own press feedback (a scale, and a low-alpha white wash), so
      // the ripple is reduced to a plain fade and the highlight removed.
      splashFactory: InkRipple.splashFactory,
      splashColor: AppColors.overlayPressed,
      highlightColor: Colors.transparent,
      visualDensity: VisualDensity.standard,

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: palette.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: textTheme.headlineSmall!.copyWith(
          color: palette.textPrimary,
        ),
        systemOverlayStyle: overlayFor(brightness),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: palette.surfaceElevated,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.sheet),
        showDragHandle: true,
        dragHandleColor: palette.textTertiary,
        dragHandleSize: const Size(32, 4),
        elevation: 0,
        modalElevation: 0,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg)),
        ),
        titleTextStyle: textTheme.headlineSmall!.copyWith(
          color: palette.textPrimary,
        ),
        contentTextStyle: textTheme.bodyMedium!.copyWith(
          color: palette.textSecondary,
        ),
      ),

      dividerTheme: DividerThemeData(
        color: palette.hairline,
        thickness: 1,
        space: 1,
      ),

      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
        iconColor: palette.textSecondary,
        titleTextStyle: textTheme.titleMedium!.copyWith(
          color: palette.textPrimary,
        ),
        subtitleTextStyle: textTheme.bodySmall!.copyWith(
          color: palette.textSecondary,
        ),
        minVerticalPadding: AppSpacing.sm,
      ),

      iconTheme: IconThemeData(color: palette.textPrimary, size: 24),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          // The `button` role, not `accent`. They are the same value in the
          // shipped identity, which is why this looks like no change — but it
          // is what lets an operator have a loud play button and quiet form
          // buttons, or the reverse. The label contrast is computed, never
          // configured: see `AurixPalette.textOnButton`.
          backgroundColor: palette.button,
          foregroundColor: palette.textOnButton,
          disabledBackgroundColor: palette.surfaceHighest,
          disabledForegroundColor: palette.textTertiary,
          minimumSize: const Size(0, AppSizes.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
          textStyle: textTheme.labelLarge!,
          shape: const StadiumBorder(),
          elevation: 0,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          side: BorderSide(color: colorScheme.outline),
          minimumSize: const Size(0, AppSizes.minTapTarget),
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
          textStyle: textTheme.labelLarge!,
          shape: const StadiumBorder(),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.textPrimary,
          textStyle: textTheme.labelLarge!,
          minimumSize: const Size(0, 40),
        ),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceElevated,
        selectedColor: palette.accent,
        disabledColor: palette.surfaceElevated,
        labelStyle: textTheme.labelMedium!.copyWith(
          color: palette.textPrimary,
        ),
        secondaryLabelStyle: textTheme.labelMedium!.copyWith(
          color: palette.textOnAccent,
        ),
        side: BorderSide(color: palette.hairline),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        showCheckmark: false,
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceElevated,
        hintStyle: textTheme.bodyMedium!.copyWith(
          color: palette.textTertiary,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide(color: palette.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide(color: palette.accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: AppRadius.field,
          borderSide: BorderSide(color: palette.accent),
        ),
        prefixIconColor: palette.textSecondary,
        suffixIconColor: palette.textSecondary,
      ),

      sliderTheme: SliderThemeData(
        trackHeight: 3,
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.accent.withValues(alpha: 0.20),
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.12),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        trackShape: const RoundedRectSliderTrackShape(),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return palette.textOnAccent;
          return palette.textTertiary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return palette.accent;
          return palette.surfaceHighest;
        }),
        trackOutlineColor: WidgetStatePropertyAll(palette.hairline),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: palette.accent,
        linearTrackColor: palette.accent.withValues(alpha: 0.16),
        linearMinHeight: 2,
      ),

      snackBarTheme: SnackBarThemeData(
        // Inverted against the page: on dark the toast is graphite, on light it
        // is near-black. A toast that matches its background needs a border to
        // be seen, and a bordered toast reads as a dialog.
        backgroundColor: isDark ? palette.surfaceHighest : const Color(0xFF1A1A1A),
        contentTextStyle: textTheme.bodyMedium!.copyWith(color: Colors.white),
        actionTextColor: Colors.white,
        behavior: SnackBarBehavior.floating,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.card),
        insetPadding: const EdgeInsets.all(AppSpacing.lg),
        elevation: 0,
      ),

      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? palette.surfaceHighest : const Color(0xFF1A1A1A),
          borderRadius: AppRadius.card,
        ),
        textStyle: textTheme.bodySmall!.copyWith(color: Colors.white),
      ),

      tabBarTheme: TabBarThemeData(
        labelColor: palette.textPrimary,
        unselectedLabelColor: palette.textTertiary,
        labelStyle: textTheme.labelLarge!,
        unselectedLabelStyle: textTheme.labelLarge!,
        indicatorColor: palette.accent,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
      ),

      popupMenuTheme: PopupMenuThemeData(
        color: palette.surfaceElevated,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: AppRadius.card),
        textStyle: textTheme.bodyLarge!.copyWith(color: palette.textPrimary),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
