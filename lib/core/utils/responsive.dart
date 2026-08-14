import 'package:flutter/widgets.dart';

import '../theme/app_dimens.dart';

enum ScreenSize { compact, medium, expanded }

/// Screen-size helpers so layouts adapt instead of hardcoding phone numbers.
///
/// Breakpoints follow Material 3's window size classes. `compact` is a phone
/// in portrait, `medium` a large phone in landscape or a small tablet,
/// `expanded` a tablet.
extension ResponsiveContext on BuildContext {
  Size get screenSize => MediaQuery.sizeOf(this);
  double get screenWidth => MediaQuery.sizeOf(this).width;
  double get screenHeight => MediaQuery.sizeOf(this).height;
  EdgeInsets get safeArea => MediaQuery.paddingOf(this);
  bool get isLandscape =>
      MediaQuery.orientationOf(this) == Orientation.landscape;

  ScreenSize get sizeClass {
    final width = screenWidth;
    if (width < 600) return ScreenSize.compact;
    if (width < 840) return ScreenSize.medium;
    return ScreenSize.expanded;
  }

  bool get isCompact => sizeClass == ScreenSize.compact;
  bool get isTablet => sizeClass == ScreenSize.expanded;

  /// Picks one of three values based on the current size class.
  T responsive<T>({required T compact, T? medium, T? expanded}) {
    switch (sizeClass) {
      case ScreenSize.compact:
        return compact;
      case ScreenSize.medium:
        return medium ?? compact;
      case ScreenSize.expanded:
        return expanded ?? medium ?? compact;
    }
  }

  /// Horizontal page gutter. Wider screens get more breathing room, and very
  /// wide screens get the content centred rather than stretched edge to edge.
  double get pageGutter => responsive(
    compact: AppSpacing.page,
    medium: AppSpacing.xxl,
    expanded: AppSpacing.xxxl,
  );

  /// Caps line length on tablets so text does not run the full 1000px.
  double get contentMaxWidth => responsive(
    compact: double.infinity,
    medium: 720,
    expanded: 1080,
  );

  /// Card width in a horizontal carousel.
  double get carouselCardWidth => responsive(
    compact: AppSizes.carouselCardWidth,
    medium: 168,
    expanded: 190,
  );

  /// Columns for a responsive grid of square cards.
  int get gridColumns => responsive(compact: 2, medium: 3, expanded: 4);

  /// Full-player artwork edge, bounded so it never overflows short screens.
  double get playerArtworkSize {
    final available = isLandscape ? screenHeight * 0.62 : screenWidth - (pageGutter * 2) - 24;
    final ceiling = isLandscape
        ? AppSizes.playerArtworkMax * 0.8
        : AppSizes.playerArtworkMax;
    return available.clamp(140.0, ceiling);
  }
}

/// Centres and width-limits a child on large screens while leaving phones
/// untouched. Wrapping page bodies in this is what makes tablet layouts stop
/// looking like stretched phone layouts.
class ContentBounds extends StatelessWidget {
  const ContentBounds({required this.child, this.maxWidth, super.key});

  final Widget child;
  final double? maxWidth;

  @override
  Widget build(BuildContext context) {
    final limit = maxWidth ?? context.contentMaxWidth;
    if (limit == double.infinity) return child;
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: limit),
        child: child,
      ),
    );
  }
}
