import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/category.dart';
import '../../data/models/playlist.dart';
import '../../data/models/search_results.dart';
import '../../data/models/track.dart';
import '../../playback/playback_queue.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/media/content_cards.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/search/aurix_search_bar.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/search_provider.dart';
import 'widgets/search_result_rows.dart';

/// The Search tab.
class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    // Restore the query when returning to the tab, so navigating into a result
    // and coming back does not wipe the search.
    final existing = ref.read(searchControllerProvider).query;
    if (existing.isNotEmpty) _textController.text = existing;
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    // Trigger a page early enough that the list rarely shows the spinner.
    if (position.pixels >= position.maxScrollExtent - 480) {
      ref.read(searchControllerProvider.notifier).loadMore();
    }
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _textController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(searchControllerProvider);
    final controller = ref.read(searchControllerProvider.notifier);

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.pageGutter,
              AppSpacing.md,
              context.pageGutter,
              AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Search', style: AppTypography.displaySmall),
                const SizedBox(height: AppSpacing.lg),
                AurixSearchBar(
                  controller: _textController,
                  focusNode: _focusNode,
                  onChanged: controller.onQueryChanged,
                  onSubmitted: controller.submit,
                  onClear: () => _focusNode.requestFocus(),
                  onVoiceSearch: _onVoiceSearch,
                ),
              ],
            ),
          ),

          if (state.hasQuery && state.results.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.sm),
              child: _FilterBar(
                available: state.results.populatedTypes,
                selected: state.activeFilter,
                onSelected: (filter) {
                  controller.setFilter(filter);
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(0);
                  }
                },
              ),
            ),

          Expanded(child: _body(state, controller)),
        ],
      ),
    );
  }

  Widget _body(SearchState state, SearchQueryController controller) {
    final bottomInset = shellBottomInset(
      context,
      hasTrack: ref.watch(hasActivePlaybackProvider),
    );

    switch (state.phase) {
      case SearchPhase.idle:
        return _BrowseView(
          recents: state.recentSearches,
          popular: controller.popularSearches(),
          bottomInset: bottomInset,
          onPick: (query) {
            _textController.text = query;
            controller.submit(query);
            _focusNode.unfocus();
          },
          onRemoveRecent: controller.removeRecent,
          onClearRecents: controller.clearRecents,
        );

      case SearchPhase.typing:
      case SearchPhase.loading:
        return ListView(
          padding: EdgeInsets.only(bottom: bottomInset),
          children: [
            SkeletonTrackList(
              itemCount: 8,
              animate: !ref.watch(reduceMotionProvider),
            ),
          ],
        );

      case SearchPhase.empty:
        return EmptyView(
          icon: AurixGlyph.search,
          title: 'No results for "${state.query}"',
          message: 'Check the spelling, or try a different artist, album or song.',
        );

      case SearchPhase.error:
        return ErrorView(
          error: state.error!,
          onRetry: () => controller.submit(state.query),
        );

      case SearchPhase.results:
        return SearchResultsView(
          results: state.results,
          filter: state.activeFilter,
          isLoadingMore: state.isLoadingMore,
          scrollController: _scrollController,
          bottomInset: bottomInset,
        );
    }
  }

  /// The microphone is part of the design, but AURIX ships no speech engine.
  /// Saying so is better than a button that appears broken.
  void _onVoiceSearch() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const AurixIcon(AurixGlyph.mic, size: 30),
        title: const Text('Voice search'),
        content: const Text(
          'Voice search is not wired up in this build. AURIX would need a '
          'speech-to-text engine and microphone permission to support it — '
          'neither is bundled, so the control is a placeholder for now.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.available,
    required this.selected,
    required this.onSelected,
  });

  final List<SearchType> available;
  final SearchType? selected;
  final ValueChanged<SearchType?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (available.length < 2) return const SizedBox.shrink();

    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: selected == null,
            onSelected: (_) => onSelected(null),
          ),
          for (final type in available) ...[
            const SizedBox(width: AppSpacing.sm),
            ChoiceChip(
              label: Text(type.label),
              selected: selected == type,
              onSelected: (_) => onSelected(type),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the user sees before typing: their history, then popular starting
/// points, then the mood tiles.
class _BrowseView extends ConsumerWidget {
  const _BrowseView({
    required this.recents,
    required this.popular,
    required this.bottomInset,
    required this.onPick,
    required this.onRemoveRecent,
    required this.onClearRecents,
  });

  final List<String> recents;
  final List<String> popular;
  final double bottomInset;
  final ValueChanged<String> onPick;
  final ValueChanged<String> onRemoveRecent;
  final VoidCallback onClearRecents;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final columns = context.gridColumns;

    return ListView(
      padding: EdgeInsets.only(bottom: bottomInset),
      children: [
        if (recents.isNotEmpty) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.pageGutter,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Recent searches', style: AppTypography.headlineSmall),
                ),
                TextButton(
                  onPressed: onClearRecents,
                  style: TextButton.styleFrom(
                    foregroundColor: context.palette.textSecondary,
                  ),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          for (final query in recents)
            ListTile(
              onTap: () => onPick(query),
              leading: const AurixIcon(AurixGlyph.history, size: 21),
              title: Text(query, style: AppTypography.bodyLarge),
              trailing: IconButton(
                onPressed: () => onRemoveRecent(query),
                icon: const AurixIcon(AurixGlyph.close, size: 17),
                tooltip: 'Remove',
                visualDensity: VisualDensity.compact,
              ),
              dense: true,
            ),
          const SizedBox(height: AppSpacing.xl),
        ],

        Padding(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            AppSpacing.sm,
            context.pageGutter,
            AppSpacing.md,
          ),
          child: Text(
            recents.isEmpty ? 'Start with' : 'Popular searches',
            style: AppTypography.headlineSmall,
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
          child: Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              for (final query in popular)
                ActionChip(
                  label: Text(query),
                  onPressed: () => onPick(query),
                  backgroundColor: context.palette.surfaceElevated,
                ),
            ],
          ),
        ),

        const SizedBox(height: AppSpacing.xxxl),

        Padding(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            0,
            context.pageGutter,
            AppSpacing.md,
          ),
          child: const Text('Browse all', style: AppTypography.headlineSmall),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
          child: LayoutBuilder(
            builder: (context, constraints) {
              const gap = AppSpacing.md;
              final tileWidth =
                  (constraints.maxWidth - (gap * (columns - 1))) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final category in MoodCatalogue.defaults)
                    CategoryCard(
                      category: category,
                      width: tileWidth,
                      height: tileWidth * 0.58,
                      onTap: () => context.pushDistinct(
                        RouteNames.category,
                        pathParameters: {'id': category.id},
                        queryParameters: {
                          'title': category.name,
                          'q': category.query,
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// The results list, in either the mixed overview or a single-type tab.
class SearchResultsView extends ConsumerWidget {
  const SearchResultsView({
    required this.results,
    required this.filter,
    required this.isLoadingMore,
    required this.scrollController,
    required this.bottomInset,
    super.key,
  });

  final SearchResults results;
  final SearchType? filter;
  final bool isLoadingMore;
  final ScrollController scrollController;
  final double bottomInset;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (filter != null) {
      return _singleType(context, ref, filter!);
    }
    return _overview(context, ref);
  }

  // ---- Mixed overview ----------------------------------------------------

  Widget _overview(BuildContext context, WidgetRef ref) {
    final top = results.topResult;

    return ListView(
      controller: scrollController,
      padding: EdgeInsets.only(bottom: bottomInset, top: AppSpacing.sm),
      children: [
        if (top != null) ...[
          Padding(
            padding: EdgeInsets.fromLTRB(
              context.pageGutter,
              0,
              context.pageGutter,
              AppSpacing.md,
            ),
            child: const Text('Top result', style: AppTypography.headlineSmall),
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
            child: TopResultCard(result: top),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],

        if (results.tracks.isNotEmpty)
          _Group(
            title: 'Songs',
            children: [
              for (var i = 0; i < results.tracks.items.take(5).length; i++)
                SongTile(
                  track: results.tracks.items[i],
                  onTap: () => _playTracks(ref, results.tracks.items, i),
                ),
            ],
          ),

        if (results.artists.isNotEmpty)
          _Group(
            title: 'Artists',
            children: [
              for (final artist in results.artists.items.take(4))
                ArtistRow(artist: artist),
            ],
          ),

        if (results.albums.isNotEmpty)
          _Group(
            title: 'Albums',
            children: [
              for (final album in results.albums.items.take(4))
                AlbumRow(album: album),
            ],
          ),

        if (results.playlists.isNotEmpty)
          _Group(
            title: 'Playlists',
            children: [
              for (final playlist in results.playlists.items.take(4))
                PlaylistRow(playlist: playlist),
            ],
          ),
      ],
    );
  }

  // ---- Single type, paged ------------------------------------------------

  Widget _singleType(BuildContext context, WidgetRef ref, SearchType type) {
    final List<Widget> rows;
    switch (type) {
      case SearchType.track:
        final items = results.tracks.items;
        rows = [
          for (var i = 0; i < items.length; i++)
            SongTile(
              track: items[i],
              showAlbumName: true,
              onTap: () => _playTracks(ref, items, i),
            ),
        ];
      case SearchType.artist:
        rows = [for (final a in results.artists.items) ArtistRow(artist: a)];
      case SearchType.album:
        rows = [for (final a in results.albums.items) AlbumRow(album: a)];
      case SearchType.playlist:
        rows = [for (final p in results.playlists.items) PlaylistRow(playlist: p)];
    }

    return ListView.builder(
      controller: scrollController,
      padding: EdgeInsets.only(bottom: bottomInset, top: AppSpacing.sm),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == rows.length) {
          return PagingIndicator(visible: isLoadingMore);
        }
        return rows[index];
      },
    );
  }

  void _playTracks(WidgetRef ref, List<Track> tracks, int index) {
    ref.read(playerControllerProvider.notifier).playTracks(
      tracks,
      startIndex: index,
      context: const PlaybackContext(title: 'Search results'),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(
            context.pageGutter,
            0,
            context.pageGutter,
            AppSpacing.sm,
          ),
          child: Text(title, style: AppTypography.headlineSmall),
        ),
        ...children,
        const SizedBox(height: AppSpacing.xl),
      ],
    );
  }
}

/// The large "Top result" card.
///
/// Takes an `Object` because Spotify's most relevant hit for a query can be
/// any of the four types — the alternative is four near-identical widgets and
/// a switch at every call site.
class TopResultCard extends ConsumerWidget {
  const TopResultCard({required this.result, super.key});

  final Object result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String title;
    final String subtitle;
    final String? imageUrl;
    final String seed;
    final ArtworkShape shape;
    final VoidCallback onTap;

    switch (result) {
      case final Artist artist:
        title = artist.name;
        subtitle = 'Artist';
        imageUrl = artist.avatarUrl;
        seed = artist.id;
        shape = ArtworkShape.circle;
        onTap = () => context.pushDistinct(
          RouteNames.artist,
          pathParameters: {'id': artist.id},
        );
      case final Album album:
        title = album.name;
        subtitle = '${album.albumType.label} · ${album.artistNames}';
        imageUrl = album.cardImageUrl;
        seed = album.id;
        shape = ArtworkShape.square;
        onTap = () => context.pushDistinct(
          RouteNames.album,
          pathParameters: {'id': album.id},
        );
      case final Playlist playlist:
        title = playlist.name;
        subtitle = 'Playlist · ${playlist.ownerName}';
        imageUrl = playlist.cardImageUrl;
        seed = playlist.id;
        shape = ArtworkShape.square;
        onTap = () => context.pushDistinct(
          RouteNames.playlist,
          pathParameters: {'id': playlist.id},
        );
      case final Track track:
        title = track.name;
        subtitle = 'Song · ${track.artistNames}';
        imageUrl = track.cardArtworkUrl;
        seed = track.id;
        shape = ArtworkShape.square;
        onTap = () => ref.read(playerControllerProvider.notifier).playTrack(track);
      default:
        return const SizedBox.shrink();
    }

    return PressableCard(
      onTap: onTap,
      semanticLabel: '$subtitle: $title',
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: context.palette.surface,
          borderRadius: AppRadius.card,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppArtwork(
              imageUrl: imageUrl,
              size: 92,
              shape: shape,
              seed: seed,
              elevated: true,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              title,
              style: AppTypography.headlineMedium,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              subtitle,
              style: AppTypography.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}
