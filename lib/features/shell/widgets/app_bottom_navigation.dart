import 'dart:ui';

import 'package:flutter/material.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/aurix_palette.dart';
import '../../../shared/widgets/icons/aurix_glyphs.dart';
import '../../../shared/widgets/icons/aurix_icon.dart';

class NavDestination {
  const NavDestination({
    required this.label,
    required this.icon,
    this.selectedIcon,
  });

  final String label;
  final AurixGlyph icon;

  /// A different glyph when selected. Most tabs keep one shape and let the
  /// emphasis treatment carry the state — only Search genuinely reads better
  /// as a second drawing.
  final AurixGlyph? selectedIcon;
}

/// The persistent bottom navigation bar.
///
/// Hand-built rather than `NavigationBar` for two reasons: the app needs the
/// bar to sit on a gradient scrim (so content scrolls *under* it rather than
/// stopping at a hard edge), and each item animates its icon and label
/// independently on selection. Material's bar gives neither without fighting it.
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    required this.currentIndex,
    required this.onDestinationSelected,
    this.destinations = defaultDestinations,
    super.key,
  });

  final int currentIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavDestination> destinations;

  /// Three destinations. The order matches the router's shell branches exactly
  /// — this bar reports an *index*, so a mismatch would silently send taps to
  /// the wrong tab rather than failing loudly.
  ///
  /// It used to carry five. Playlists and Profile are pushed pages now; see the
  /// note beside their routes in `app_router.dart` for why neither earns a tab.
  /// Three is also what lets each item breathe: at five, "Playlists" clipped at
  /// a 1.3 text scale and the labels had to drop to 9.5px to fit.
  static const List<NavDestination> defaultDestinations = <NavDestination>[
    NavDestination(label: 'Home', icon: AurixGlyph.home),
    NavDestination(
      label: 'Search',
      icon: AurixGlyph.search,
      selectedIcon: AurixGlyph.searchActive,
    ),
    NavDestination(label: 'Library', icon: AurixGlyph.library),
  ];

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final palette = context.palette;

    // Frosted, like the mini player directly above it. The two are the app's
    // only permanently-floating chrome, so they have to be made of the same
    // material — a blurred bar under a solid one reads as two unrelated
    // layers.
    //
    // The gradient underneath is still here and still necessary: blur alone
    // does not guarantee contrast, and a white label over a bright album
    // thumbnail scrolling past needs the ground to darken as well as soften.
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                palette.ground.withValues(alpha: 0),
                palette.ground.withValues(alpha: 0.86),
                palette.ground.withValues(alpha: 0.96),
              ],
              stops: const [0, 0.35, 1],
            ),
            // A hairline along the top edge. Neutral, not the accent: a lit
            // strip under the mini player put two competing bright edges
            // within 8px of each other.
            border: Border(
              top: BorderSide(color: palette.hairline, width: 0.8),
            ),
          ),
          child: SizedBox(
            height: AppSizes.bottomNavHeight + bottomInset,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomInset),
              child: Row(
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    Expanded(
                      child: _NavItem(
                        destination: destinations[i],
                        selected: i == currentIndex,
                        onTap: () => onDestinationSelected(i),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.selected,
    required this.onTap,
  });

  final NavDestination destination;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Brief §4: selected is white, unselected is grey. With one accent that
    // *is* the whole state — which is why the emphasis disc below matters, and
    // why the label also changes weight.
    final color = selected ? palette.textPrimary : palette.textTertiary;

    return Semantics(
      button: true,
      selected: selected,
      label: destination.label,
      // One merged node per tab. Without this a screen reader announces the
      // label twice — once from here and once from the Text below.
      container: true,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // The selected glyph carries the icon set's own emphasis treatment
            // — the soft backing disc — rather than anything painted here. One
            // treatment, defined once, used by every emphasised icon in the
            // app.
            //
            // The 0.42-alpha bloom that used to sit behind it is gone. On a
            // frosted bar it was a white halo on a white icon: it blurred the
            // glyph's edge instead of lifting it, which made the *selected* tab
            // the least legible one.
            AnimatedContainer(
              duration: AppConstants.medium,
              curve: Curves.easeOut,
              decoration: const BoxDecoration(shape: BoxShape.circle),
              child: AnimatedSwitcher(
                duration: AppConstants.fast,
                transitionBuilder: (child, animation) => ScaleTransition(
                  scale: Tween<double>(begin: 0.82, end: 1).animate(animation),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: AurixIcon(
                  selected
                      ? (destination.selectedIcon ?? destination.icon)
                      : destination.icon,
                  key: ValueKey(selected),
                  size: 24,
                  color: color,
                  emphasis: selected,
                ),
              ),
            ),
            const SizedBox(height: 3),
            AnimatedDefaultTextStyle(
              duration: AppConstants.fast,
              style: AppTypography.labelMedium.copyWith(
                color: color,
                // Back up from 9.5px, which was what five labels forced.
                // "Library" is the longest of the three and clears a 1.3 text
                // scale comfortably here.
                fontSize: 11,
                letterSpacing: 0.1,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
              child: Text(
                destination.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
