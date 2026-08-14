import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/error_mapper.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/artist.dart';
import '../../data/models/playlist.dart';
import '../../data/models/saved_item.dart';
import '../../data/repositories/library_repository.dart';
import '../../playback/playback_queue.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/media/aurix_avatar.dart';
import '../../shared/widgets/search/aurix_search_bar.dart';
import '../auth/providers/auth_provider.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/library_provider.dart';
import 'widgets/library_rows.dart';

/// The Library tab.
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _searchVisible = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(librarySnapshotProvider);
    final filter = ref.watch(libraryFilterProvider);
    final sort = ref.watch(librarySortProvider);
    final query = ref.watch(librarySearchProvider);

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(librarySnapshotProvider);
        await ref.read(librarySnapshotProvider.future);
      },
      color: context.palette.accent,
      backgroundColor: context.palette.surfaceElevated,
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              searchVisible: _searchVisible,
              onToggleSearch: () {
                setState(() => _searchVisible = !_searchVisible);
                if (!_searchVisible) {
                  _searchController.clear();
                  ref.read(librarySearchProvider.notifier).state = '';
                }
              },
              sort: sort,
              onSortChanged: (value) =>
                  ref.read(librarySortProvider.notifier).set(value),
            ),

            if (_searchVisible)
              Padding(
                padding: EdgeInsets.fromLTRB(
                  context.pageGutter,
                  0,
                  context.pageGutter,
                  AppSpacing.md,
                ),
                child: AurixSearchBar(
                  controller: _searchController,
                  autofocus: true,
                  hintText: 'Search in your library',
                  onChanged: (value) =>
                      ref.read(librarySearchProvider.notifier).state = value,
                ),
              ),

            FilterChipRow<LibraryFilter>(
              values: LibraryFilter.values,
              selected: filter,
              labelOf: (value) => value.label,
              onSelected: (value) => ref
                  .read(libraryFilterProvider.notifier)
                  .set(value ?? LibraryFilter.all),
              padding: EdgeInsets.symmetric(horizontal: context.pageGutter),
            ),

            const SizedBox(height: AppSpacing.sm),

            Expanded(
              child: snapshot.when(
                data: (data) => _LibraryList(
                  snapshot: data,
                  filter: filter,
                  sort: sort,
                  query: query,
                ),
                loading: () => SingleChildScrollView(
                  child: SkeletonTrackList(
                    itemCount: 9,
                    animate: !ref.watch(reduceMotionProvider),
                  ),
                ),
                error: (error, _) => ErrorView(
                  error: ErrorMapper.fromUnknown(error),
                  onRetry: () => ref.invalidate(librarySnapshotProvider),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header({
    required this.searchVisible,
    required this.onToggleSearch,
    required this.sort,
    required this.onSortChanged,
  });

  final bool searchVisible;
  final VoidCallback onToggleSearch;
  final LibrarySort sort;
  final ValueChanged<LibrarySort> onSortChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);

    return Padding(
      padding: EdgeInsets.fromLTRB(
        context.pageGutter,
        AppSpacing.md,
        context.pageGutter - AppSpacing.sm,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          if (user != null) ...[
            InkWell(
              onTap: () => context.pushDistinct(RouteNames.profile),
              customBorder: const CircleBorder(),
              child: AurixAvatar.of(size: AppSizes.avatarSm),
            ),
            const SizedBox(width: AppSpacing.md),
          ],
          const Expanded(
            child: Text('Your library', style: AppTypography.displaySmall),
          ),
          IconButton(
            onPressed: onToggleSearch,
            icon: AurixIcon(searchVisible ? AurixGlyph.close : AurixGlyph.search),
            tooltip: searchVisible ? 'Close search' : 'Search library',
          ),
          PopupMenuButton<LibrarySort>(
            initialValue: sort,
            onSelected: onSortChanged,
            tooltip: 'Sort',
            icon: const AurixIcon(AurixGlyph.sort),
            itemBuilder: (context) => [
              for (final value in LibrarySort.values)
                PopupMenuItem<LibrarySort>(
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

/// The filtered, sorted, searched list.
///
/// All three operations happen locally over already-loaded data: the library
/// is fetched once and then sliced, so switching filters and typing in the
/// search box are instant and work offline.
class _LibraryList extends ConsumerWidget {
  const _LibraryList({
    required this.snapshot,
    required this.filter,
    required this.sort,
    required this.query,
  });

  final LibrarySnapshot snapshot;
  final LibraryFilter filter;
  final LibrarySort sort;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rows = _buildRows(context, ref);

    if (rows.isEmpty) {
      return EmptyView(
        icon: query.isNotEmpty
            ? AurixGlyph.search
            : AurixGlyph.library,
        title: query.isNotEmpty ? 'No matches' : 'Nothing saved yet',
        message: query.isNotEmpty
            ? 'Nothing in your library matches "$query".'
            : 'Save albums, follow artists and like songs — they land here.',
        actionLabel: query.isNotEmpty ? null : 'Browse',
        onAction: query.isNotEmpty
            ? null
            : () => context.goNamed(RouteNames.search),
      );
    }

    final bottomInset = shellBottomInset(
      context,
      hasTrack: ref.watch(hasActivePlaybackProvider),
    );

    return ListView.builder(
      padding: EdgeInsets.only(bottom: bottomInset),
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
    );
  }

  List<Widget> _buildRows(BuildContext context, WidgetRef ref) {
    final rows = <Widget>[];
    final showAll = filter == LibraryFilter.all;

    // Liked Songs is a synthetic entry, pinned above the rest — it is the one
    // "playlist" a user always has and always wants first.
    if ((showAll || filter == LibraryFilter.liked) &&
        snapshot.likedTracks.isNotEmpty &&
        _matches('Liked Songs')) {
      rows.add(
        LikedSongsRow(
          count: snapshot.likedTracks.length,
          onTap: () => context.pushDistinct(RouteNames.likedSongs),
        ),
      );
    }

    if (showAll || filter == LibraryFilter.playlists) {
      final playlists = _sortPlaylists(
        snapshot.playlists.where((p) => _matches(p.name, p.ownerName)).toList(),
      );
      rows.addAll(playlists.map((p) => LibraryPlaylistRow(playlist: p)));
    }

    if (showAll || filter == LibraryFilter.albums) {
      final albums = _sortAlbums(
        snapshot.savedAlbums
            .where((a) => _matches(a.album.name, a.album.artistNames))
            .toList(),
      );
      rows.addAll(albums.map((a) => LibraryAlbumRow(saved: a)));
    }

    if (showAll || filter == LibraryFilter.artists) {
      final artists = _sortArtists(
        snapshot.followedArtists.where((a) => _matches(a.name)).toList(),
      );
      rows.addAll(artists.map((a) => LibraryArtistRow(artist: a)));
    }

    if (filter == LibraryFilter.recent) {
      // De-duplicated: recently-played repeats a track per play.
      final seen = <String>{};
      for (final entry in snapshot.recentlyPlayed) {
        if (!seen.add(entry.track.id)) continue;
        if (!_matches(entry.track.name, entry.track.artistNames)) continue;
        rows.add(
          RecentlyPlayedRow(
            entry: entry,
            onTap: () => ref.read(playerControllerProvider.notifier).playTracks(
              snapshot.recentlyPlayed.map((e) => e.track).toList(),
              startIndex: snapshot.recentlyPlayed.indexOf(entry),
              context: const PlaybackContext(title: 'Recently played'),
            ),
          ),
        );
      }
    }

    return rows;
  }

  bool _matches(String primary, [String? secondary]) {
    if (query.trim().isEmpty) return true;
    final needle = query.trim().toLowerCase();
    return primary.toLowerCase().contains(needle) ||
        (secondary?.toLowerCase().contains(needle) ?? false);
  }

  List<Playlist> _sortPlaylists(List<Playlist> items) {
    switch (sort) {
      case LibrarySort.alphabetical:
        return items..sort((a, b) => _compareNames(a.name, b.name));
      case LibrarySort.creator:
        return items..sort((a, b) => _compareNames(a.ownerName, b.ownerName));
      case LibrarySort.recentlyAdded:
        // Spotify returns /me/playlists in its own order, which is already
        // "most recently interacted with" — leave it alone.
        return items;
    }
  }

  List<SavedAlbum> _sortAlbums(List<SavedAlbum> items) {
    switch (sort) {
      case LibrarySort.alphabetical:
        return items..sort((a, b) => _compareNames(a.album.name, b.album.name));
      case LibrarySort.creator:
        return items
          ..sort((a, b) => _compareNames(a.album.artistNames, b.album.artistNames));
      case LibrarySort.recentlyAdded:
        return items
          ..sort((a, b) {
            final aDate = a.addedAt;
            final bDate = b.addedAt;
            if (aDate == null || bDate == null) return 0;
            return bDate.compareTo(aDate);
          });
    }
  }

  List<Artist> _sortArtists(List<Artist> items) {
    switch (sort) {
      case LibrarySort.alphabetical:
      case LibrarySort.creator:
        return items..sort((a, b) => _compareNames(a.name, b.name));
      case LibrarySort.recentlyAdded:
        return items;
    }
  }

  /// Case-insensitive comparison so "abba" and "ABBA" sort together rather
  /// than uppercase names all landing before lowercase ones.
  int _compareNames(String a, String b) =>
      a.toLowerCase().compareTo(b.toLowerCase());
}

/// Re-exported so the Liked Songs screen can format counts identically.
String describeTrackCount(int count) =>
    '${Formatters.groupedNumber(count)} ${count == 1 ? 'song' : 'songs'}';
