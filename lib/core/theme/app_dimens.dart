import 'package:flutter/widgets.dart';

/// Spacing, radii and fixed component sizes.
///
/// Layout code composes from this scale instead of typing raw numbers, which
/// is what keeps rhythm consistent across twelve screens written at different
/// times. Anything that must adapt to screen size lives in
/// `core/utils/responsive.dart` instead — these are constants, not breakpoints.
abstract final class AppSpacing {
  static const double xxs = 2;
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;
  static const double huge = 48;

  /// Standard horizontal page gutter.
  static const double page = 16;

  /// Gap between cards in a horizontal carousel.
  static const double carouselGap = 12;

  /// Gap between vertically stacked home sections.
  static const double sectionGap = 28;
}

abstract final class AppRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 22;
  static const double pill = 999;

  static const BorderRadius card = BorderRadius.all(Radius.circular(md));
  static const BorderRadius artwork = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius sheet = BorderRadius.vertical(top: Radius.circular(xl));
  static const BorderRadius field = BorderRadius.all(Radius.circular(sm));
}

abstract final class AppSizes {
  /// Height of the mini player, excluding its progress hairline.
  static const double miniPlayerHeight = 62;

  /// Height of the custom bottom navigation bar, excluding safe area.
  static const double bottomNavHeight = 62;

  // ---- Dynamic Island ---------------------------------------------------
  // The floating pill AURIX draws for itself. Fixed rather than intrinsic:
  // the collapsed and expanded boxes are interpolated on every frame of the
  // transition, and interpolating between two sizes nobody has measured yet
  // is how a morph turns into a jump.

  /// Collapsed pill. Tall enough for a 34px cover plus breathing room, short
  /// enough to read as chrome rather than as a bar.
  static const double islandCollapsedHeight = 46;
  static const double islandCollapsedWidth = 250;

  /// Expanded card. The compact variant is used where the viewport is too
  /// short to give a third of itself to a music control — a phone in
  /// landscape, mostly.
  static const double islandExpandedHeight = 138;
  static const double islandExpandedCompactHeight = 122;
  static const double islandExpandedWidth = 360;

  /// Below this viewport height the expanded island uses its compact box.
  static const double islandCompactViewportHeight = 560;

  /// Square edge of a carousel card's artwork on a phone.
  static const double carouselCardWidth = 152;
  static const double compactCardWidth = 132;

  /// Leading artwork in a list row.
  static const double tileArtwork = 48;
  static const double tileArtworkLarge = 56;

  /// Avatar sizes.
  static const double avatarSm = 30;
  static const double avatarMd = 44;
  static const double avatarLg = 96;

  /// Immersive header height before scroll collapse.
  static const double headerExpanded = 340;
  static const double headerCollapsed = 56;

  /// Minimum tap target, per Material accessibility guidance.
  static const double minTapTarget = 44;

  /// Full-screen player artwork ceiling; below this it scales with the screen.
  static const double playerArtworkMax = 400;
}
