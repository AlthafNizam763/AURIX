import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/error_mapper.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/playlist.dart';
import '../../shared/widgets/effects/grain.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/content_cards.dart';
import '../auth/providers/auth_provider.dart';
import '../library/providers/library_provider.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';

/// Sort orders for the Playlists tab.
///
/// Deliberately fewer options than the Library tab: playlists have no "date
/// added" that Spotify reports for a follow, so offering "Recently added"
/// here would sort by an order the API only incidentally returns.
enum PlaylistSort {
  none('Default'),
  alphabetical('A–Z'),
  size('Most tracks');

  const PlaylistSort(this.label);
  final String label;
}

/// Which playlists to show — everything the user follows, or only the ones
/// they made.
enum PlaylistScope {
  all('All'),
  mine('Made by you');

  const PlaylistScope(this.label);
  final String label;
}

final _playlistScopeProvider =
    StateProvider.autoDispose<PlaylistScope>((ref) => PlaylistScope.all);

final _playlistSortProvider =
    StateProvider.autoDispose<PlaylistSort>((ref) => PlaylistSort.none);

/// The Playlists tab.
///
/// Reads [librarySnapshotProvider] rather than fetching its own page: the
/// Library tab has already loaded the same list, and a second request would
/// spend quota to display data the app is holding. Invalidating the snapshot
/// refreshes both tabs at once.
class PlaylistsScreen extends ConsumerWidget {
  const PlaylistsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(librarySnapshotProvider);
    final scope = ref.watch(_playlistScopeProvider);
    final sort = ref.watch(_playlistSortProvider);
    final userId = ref.watch(currentUserIdProvider);

    return RefreshIndicator(
      onRefresh: () => refreshLibrary(ref),
      color: context.palette.accent,
      backgroundColor: context.palette.surfaceElevated,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            const _PlaylistsHeader(),

            _ScopeBar(
              scope: scope,
              sort: sort,
              onScope: (value) =>
                  ref.read(_playlistScopeProvider.notifier).state = value,
              onSort: (value) =>
                  ref.read(_playlistSortProvider.notifier).state = value,
            ),

            Expanded(
              child: snapshot.when(
                data: (data) => _PlaylistGrid(
                  playlists: arrangePlaylists(
                    data.playlists,
                    scope: scope,
                    sort: sort,
                    userId: userId,
                  ),
                  totalBeforeFilter: data.playlists.length,
                  scope: scope,
                  onClearScope: () => ref
                      .read(_playlistScopeProvider.notifier)
                      .state = PlaylistScope.all,
                ),
                loading: () => SingleChildScrollView(
                  child: SkeletonTrackList(
                    itemCount: 8,
                    animate: !ref.watch(reduceMotionProvider),
                  ),
                ),
                error: (error, _) => ErrorView(
                  error: ErrorMapper.fromUnknown(error),
                  onRetry: () => refreshLibrary(ref),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

}

/// Filters then sorts. Pure and top-level so it stays trivially testable — see
/// `test/unit/playlist_arrange_test.dart`.
///
/// Never sorts [source] in place: the list belongs to the library snapshot,
/// and reordering it here would silently change the order every other screen
/// reading that snapshot sees.
List<Playlist> arrangePlaylists(
  List<Playlist> source, {
  required PlaylistScope scope,
  required PlaylistSort sort,
  String? userId,
}) {
  final filtered = switch (scope) {
    PlaylistScope.all => source,
    // With no signed-in user id there is nothing to compare against, so
    // "Made by you" degrades to showing everything rather than to an empty
    // screen that looks like a failure.
    PlaylistScope.mine => userId == null
        ? source
        : source.where((p) => p.owner?.id == userId).toList(),
  };

  final sorted = [...filtered];
  switch (sort) {
    case PlaylistSort.alphabetical:
      sorted.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    case PlaylistSort.size:
      sorted.sort((a, b) => b.trackCount.compareTo(a.trackCount));
    case PlaylistSort.none:
      break;
  }
  return sorted;
}

class _PlaylistsHeader extends StatelessWidget {
  const _PlaylistsHeader();

  @override
  Widget build(BuildContext context) {
    // Plain padding. A decorative web used to sit behind this header; the
    // monochrome identity carries a screen title with type and space alone,
    // which is what the extra top gutter below is for.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.pageGutter,
        AppSpacing.lg,
        context.pageGutter,
        AppSpacing.md,
      ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'YOUR COLLECTION',
                    // Tertiary, not the accent. An overline set in the accent
                    // outranked the title beneath it once the accent went
                    // white — the eye reads the brightest thing first, and the
                    // brightest thing here has to be the word "Playlists".
                    style: AppTypography.overline.copyWith(
                      color: context.palette.textTertiary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text('Playlists', style: AppTypography.displaySmall),
                ],
              ),
            ),
          ],
        ),
    );
  }
}

class _ScopeBar extends StatelessWidget {
  const _ScopeBar({
    required this.scope,
    required this.sort,
    required this.onScope,
    required this.onSort,
  });

  final PlaylistScope scope;
  final PlaylistSort sort;
  final ValueChanged<PlaylistScope> onScope;
  final ValueChanged<PlaylistSort> onSort;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(right: context.pageGutter - AppSpacing.sm),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
                children: [
                  for (final value in PlaylistScope.values) ...[
                    ChoiceChip(
                      label: Text(value.label),
                      selected: value == scope,
                      onSelected: (_) => onScope(value),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                  ],
                ],
              ),
            ),
          ),
          PopupMenuButton<PlaylistSort>(
            tooltip: 'Sort playlists',
            initialValue: sort,
            onSelected: onSort,
            icon: const AurixIcon(AurixGlyph.sort),
            itemBuilder: (context) => [
              for (final value in PlaylistSort.values)
                PopupMenuItem<PlaylistSort>(
                  value: value,
                  child: Row(
                    children: [
                      AurixIcon(
                        value == sort
                            ? AurixGlyph.checkCircle
                            : AurixGlyph.circle,
                        size: 18,
                        color: value == sort
                            ? context.palette.accent
                            : context.palette.textTertiary,
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Text(value.label),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PlaylistGrid extends ConsumerWidget {
  const _PlaylistGrid({
    required this.playlists,
    required this.totalBeforeFilter,
    required this.scope,
    required this.onClearScope,
  });

  final List<Playlist> playlists;
  final int totalBeforeFilter;
  final PlaylistScope scope;
  final VoidCallback onClearScope;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (playlists.isEmpty) {
      // Two genuinely different empty states. "You follow playlists but none
      // are yours" is a filter result and offers a way out; "you follow none
      // at all" is not, and offering a filter reset there would be nonsense.
      final filteredOut = totalBeforeFilter > 0 && scope != PlaylistScope.all;
      return EmptyView(
        icon: AurixGlyph.playlist,
        title: filteredOut ? 'None made by you yet' : 'No playlists yet',
        message: filteredOut
            ? 'You follow $totalBeforeFilter '
                  '${totalBeforeFilter == 1 ? 'playlist' : 'playlists'} made by '
                  'other people.'
            : 'Playlists you create or follow in Spotify appear here.',
        actionLabel: filteredOut ? 'Show all' : null,
        onAction: filteredOut ? onClearScope : null,
      );
    }

    final columns = context.responsive(compact: 2, medium: 3, expanded: 4);

    return GrainOverlay(
      fade: GrainFade.top,
      child: ShellAwarePadding(
        child: GridView.builder(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            AppSpacing.sm,
            context.pageGutter,
            AppSpacing.xl,
          ),
          physics: const AlwaysScrollableScrollPhysics(
            parent: BouncingScrollPhysics(),
          ),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: AppSpacing.lg,
            crossAxisSpacing: AppSpacing.md,
            // Artwork is square; the extra height is the two text lines under
            // it. Expressed as a ratio so it tracks the column width.
            childAspectRatio: 0.72,
          ),
          itemCount: playlists.length,
          itemBuilder: (context, index) {
            final playlist = playlists[index];
            return PlaylistCard(
              playlist: playlist,
              // The card sizes itself from `width`; inside a grid the cell
              // already constrains it, so this only has to be large enough not
              // to shrink the artwork.
              width: double.infinity,
              onTap: () => context.pushDistinct(
                RouteNames.playlist,
                pathParameters: {'id': playlist.id},
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Summary line used under the header when a filter is active.
String playlistCountLabel(int count) =>
    '${Formatters.groupedNumber(count)} ${count == 1 ? 'playlist' : 'playlists'}';
