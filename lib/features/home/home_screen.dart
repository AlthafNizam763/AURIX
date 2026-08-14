import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_mapper.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/home_feed.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/home_provider.dart';
import 'widgets/home_header.dart';
import 'widgets/home_shelf_view.dart';

/// The Home tab.
///
/// Every shelf on this page is built from live Spotify data and each one is
/// allowed to be absent — see `HomeRepository`. The screen therefore renders
/// whatever came back rather than assuming a fixed set of sections, which is
/// what lets it look complete on a brand-new account with no listening history
/// and on a developer app without extended API quota.
class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(homeFeedProvider);
    final reduceMotion = ref.watch(reduceMotionProvider);

    return RefreshIndicator(
      onRefresh: () => refreshHome(ref),
      color: context.palette.accent,
      backgroundColor: context.palette.surfaceElevated,
      displacement: 72,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: [
          const HomeHeader(),
          ...feed.when(
            data: (data) => _content(context, ref, data, reduceMotion),
            loading: () => _loading(context, reduceMotion),
            error: (error, _) => _error(ref, error),
          ),
          // Reserves room for the mini player and nav bar so the final shelf
          // is scrollable clear of them.
          SliverToBoxAdapter(
            child: SizedBox(
              height: shellBottomInset(
                context,
                hasTrack: ref.watch(hasActivePlaybackProvider),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _content(
    BuildContext context,
    WidgetRef ref,
    HomeFeed feed,
    bool reduceMotion,
  ) {
    final shelves = feed.visibleShelves;

    if (shelves.isEmpty) {
      return [
        SliverFillRemaining(
          hasScrollBody: false,
          child: EmptyView(
            icon: AurixGlyph.search,
            title: 'Nothing to show yet',
            message: 'Listen to something on Spotify and your feed will fill in. '
                'Or head to Search to find something new.',
            actionLabel: 'Refresh',
            onAction: () => ref.invalidate(homeFeedProvider),
          ),
        ),
      ];
    }

    return [
      if (feed.isStale)
        const SliverToBoxAdapter(child: _StaleNotice()),

      SliverPadding(
        padding: const EdgeInsets.only(top: AppSpacing.sm),
        sliver: SliverList.separated(
          itemCount: shelves.length,
          separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sectionGap),
          itemBuilder: (context, index) {
            final shelf = HomeShelfView(shelf: shelves[index]);
            if (reduceMotion) return shelf;

            // Staggered entrance, capped so the eighth shelf is not still
            // fading in a second after the page settles.
            final delay = Duration(milliseconds: 40 * (index.clamp(0, 5)));
            return shelf
                .animate(delay: delay)
                .fadeIn(duration: AppConstants.medium)
                .slideY(begin: 0.08, end: 0, curve: Curves.easeOutCubic);
          },
        ),
      ),
    ];
  }

  List<Widget> _loading(BuildContext context, bool reduceMotion) {
    final width = context.carouselCardWidth;
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: AppSpacing.sm),
          child: Column(
            children: [
              SkeletonShelf(cardWidth: width, animate: !reduceMotion),
              const SizedBox(height: AppSpacing.sectionGap),
              SkeletonShelf(cardWidth: width, animate: !reduceMotion),
              const SizedBox(height: AppSpacing.sectionGap),
              SkeletonShelf(
                cardWidth: width,
                circular: true,
                animate: !reduceMotion,
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _error(WidgetRef ref, Object error) {
    return [
      SliverFillRemaining(
        hasScrollBody: false,
        child: ErrorView(
          error: ErrorMapper.fromUnknown(error),
          onRetry: () => ref.invalidate(homeFeedProvider),
        ),
      ),
    ];
  }
}

/// Banner shown when the feed came from cache because the network was down.
class _StaleNotice extends StatelessWidget {
  const _StaleNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: EdgeInsets.fromLTRB(
        context.pageGutter,
        AppSpacing.sm,
        context.pageGutter,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm + 2,
      ),
      decoration: BoxDecoration(
        color: context.palette.surface,
        borderRadius: AppRadius.card,
        border: Border.all(color: context.palette.hairline),
      ),
      child: Row(
        children: [
          AurixIcon(AurixGlyph.history, size: 15, color: context.palette.textTertiary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Showing your last synced feed. Pull down to refresh.',
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

/// Exposed for the widget tests, which assert the loading → data transition
/// without needing to reach into private state.
@visibleForTesting
ApiException homeErrorFor(Object error) => ErrorMapper.fromUnknown(error);
