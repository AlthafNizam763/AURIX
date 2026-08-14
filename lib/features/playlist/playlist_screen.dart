import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/error_mapper.dart';
import '../../core/providers/app_providers.dart';
import '../../core/router/navigation.dart';
import '../../core/router/route_names.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/app_logger.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../core/utils/share_helper.dart';
import '../../data/models/playlist.dart';
import '../../data/models/track.dart';
import '../../data/repositories/catalogue_repository.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/layout/detail_action_bar.dart';
import '../../shared/widgets/layout/gradient_header.dart';
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../album/providers/detail_providers.dart';
import '../auth/providers/auth_provider.dart';
import '../library/providers/saved_tracks_provider.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';

/// Playlist detail.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(playlistDetailProvider(playlistId));

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: detail.when(
        data: (data) => _PlaylistContent(detail: data),
        loading: () => _Loading(reduceMotion: ref.watch(reduceMotionProvider)),
        error: (error, _) => SafeArea(
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  onPressed: () => context.pop(),
                  icon: const AurixIcon(AurixGlyph.back),
                  tooltip: 'Back',
                ),
              ),
              Expanded(
                child: ErrorView(
                  error: ErrorMapper.fromUnknown(error),
                  onRetry: () => ref.invalidate(playlistDetailProvider(playlistId)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistContent extends ConsumerStatefulWidget {
  const _PlaylistContent({required this.detail});

  final PlaylistDetail detail;

  @override
  ConsumerState<_PlaylistContent> createState() => _PlaylistContentState();
}

class _PlaylistContentState extends ConsumerState<_PlaylistContent> {
  late Playlist _playlist = widget.detail.playlist;

  /// Null means Spotify declined to say whether this playlist is saved — see
  /// `SpotifyPlaylistService.isFollowing`. The heart renders indeterminate
  /// rather than empty, because an empty heart is a claim.
  late bool? _isSaved = widget.detail.isSaved;

  bool _savePending = false;

  final ScrollController _scrollController = ScrollController();

  /// Guards the pager so a fling that crosses the threshold on several frames
  /// does not fire the same request repeatedly.
  bool _loadingMore = false;
  bool _pagingFailed = false;

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients || _loadingMore || _pagingFailed) return;
    final position = _scrollController.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    unawaited(_loadMore());
  }

  /// Pulls the next page of contents.
  ///
  /// The first page arrives with the playlist; the rest are fetched here as the
  /// user reaches the end, so opening a 5,000-track playlist costs one request
  /// rather than a hundred.
  Future<void> _loadMore() async {
    final page = _playlist.items;
    if (page == null || !page.hasMore) return;

    setState(() => _loadingMore = true);
    try {
      final next = await ref
          .read(catalogueRepositoryProvider)
          .morePlaylistItems(_playlist.id, offset: page.items.length);

      if (!mounted) return;
      if (next == null) {
        // Spotify stopped serving the contents part-way through. Keep what is
        // on screen and stop asking rather than looping on a refusal.
        setState(() => _pagingFailed = true);
        return;
      }
      setState(() => _playlist = _playlist.copyWith(items: page.append(next)));
      // The rows that just arrived have no answer yet; ask for them in one batch.
      _requestSavedState();
    } on Object catch (error) {
      if (!mounted) return;
      AppLogger.debug('Playlist paging failed: $error', scope: 'playlist');
      setState(() => _pagingFailed = true);
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  /// Rows removed locally while their DELETE is in flight, so the list reflects
  /// the action immediately and can be put back if the write fails.
  final Set<String> _removing = {};

  List<PlaylistItem> get _items => _playlist.items?.items ?? const [];
  List<Track> get _playableTracks => _playlist.playableTracks;

  @override
  void initState() {
    super.initState();
    ref.read(albumPaletteServiceProvider).resolve(_playlist.imageUrl);
    _scrollController.addListener(_onScroll);
    _requestSavedState();
  }

  /// Asks the shared store about the rows now on screen.
  ///
  /// From the lifecycle rather than from `build`, and re-run after each page so
  /// tracks that arrive on scroll get their hearts too. The store batches and
  /// de-duplicates, so a page whose tracks were already answered for costs no
  /// request.
  void _requestSavedState() {
    ref
        .read(savedTracksProvider.notifier)
        .ensureKnown(_playableTracks.map((t) => t.id));
  }

  @override
  Widget build(BuildContext context) {
    final palette = watchPalette(ref, _playlist.imageUrl);
    // The badge, not the whole state — the track list here reads no position,
    // and watching the full state rebuilt every row twice a second.
    final playback = ref.watch(playbackBadgeProvider);
    final isThisPlaylistPlaying = playback.contextUri == _playlist.spotifyUri;
    final currentUserId = ref.watch(currentUserIdProvider);
    final isOwner = _playlist.owner?.id == currentUserId;

    final visible = _items.where((i) {
      final id = i.track?.id;
      return id == null || !_removing.contains(id);
    }).toList();

    final description = Formatters.plainText(_playlist.description);
    final totalDuration = _playableTracks.fold<Duration>(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );

    // One shared answer for the whole app, so a heart filled in the player is
    // already filled when the user comes back to this list.
    final saved = ref.watch(savedTracksProvider);

    // Recomputed from the live playlist rather than taken from `widget.detail`,
    // because paging replaces `_playlist` as the user scrolls.
    final page = _playlist.items;
    final status = page == null
        ? PlaylistItemsStatus.unavailable
        : (page.items.isEmpty
              ? PlaylistItemsStatus.empty
              : PlaylistItemsStatus.loaded);
    final trackTotal =
        (page != null && page.total > 0) ? page.total : _playlist.trackCount;

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ImmersiveHeader(
          title: _playlist.name,
          overline: _playlist.isCollaborative ? 'Collaborative playlist' : 'Playlist',
          subtitle: 'By ${_playlist.ownerName}',
          palette: palette,
          expandedHeight: description.isEmpty ? AppSizes.headerExpanded : 380,
          artwork: AppArtwork(
            imageUrl: _playlist.imageUrl,
            size: context.responsive(compact: 190, medium: 214, expanded: 234),
            seed: _playlist.id,
            fallbackIcon: AurixGlyph.playlist,
            elevated: true,
            heroTag: 'playlist-${_playlist.id}',
          ),
          metadata: MetadataStrip(
            parts: <String>[
              if (_playlist.followers != null && _playlist.followers! > 0)
                '${Formatters.compactNumber(_playlist.followers!)} likes',
              // The contents page's own total when the detail response omitted
              // its summary count, and nothing at all when Spotify would not
              // enumerate the playlist — "0 songs" beside a playlist that
              // obviously has some is worse than no count.
              if (status != PlaylistItemsStatus.unavailable)
                '$trackTotal ${trackTotal == 1 ? 'song' : 'songs'}',
              if (totalDuration > Duration.zero)
                Formatters.longDuration(totalDuration),
            ],
          ),
          actions: [
            IconButton(
              onPressed: _share,
              icon: const AurixIcon(AurixGlyph.share),
              tooltip: 'Share',
            ),
          ],
        ),

        if (description.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.page,
                AppSpacing.md,
                AppSpacing.page,
                0,
              ),
              child: Text(
                description,
                style: AppTypography.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ),
          ),

        SliverToBoxAdapter(
          child: DetailActionBar(
            isPlaying: isThisPlaylistPlaying && playback.isPlaying,
            isShuffled: isThisPlaylistPlaying && playback.shuffled,
            // Saving your own playlist is meaningless — Spotify models it as
            // following, and you already follow what you own.
            isSaved: isOwner ? null : _isSaved,
            playEnabled: _playableTracks.isNotEmpty,
            onPlay: _togglePlay,
            onShuffle: _shuffle,
            onSaveToggle: _toggleSave,
            saveTooltip: (_isSaved ?? false)
                ? 'Remove from your library'
                : 'Save playlist',
            onShare: _share,
            onMore: _showMore,
          ),
        ),

        if (widget.detail.isStale)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: Row(
                children: [
                  AurixIcon(
                    AurixGlyph.offline,
                    size: 14,
                    color: context.palette.textTertiary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Offline — showing saved details.',
                      style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Three outcomes, not one. A playlist Spotify refuses to enumerate is
        // not an empty playlist, and saying so was the reported bug: a 200 on
        // the detail request, a correct name, cover and follower count, and
        // "This playlist is empty" underneath.
        if (visible.isEmpty && status == PlaylistItemsStatus.unavailable)
          const SliverToBoxAdapter(
            child: EmptyView(
              icon: AurixGlyph.info,
              title: "Spotify won't share this playlist's songs",
              message:
                  'The playlist loaded, but Spotify does not allow this app to '
                  'read its contents. This is an access restriction on '
                  "Spotify's side, not a problem with the playlist.",
              compact: true,
            ),
          )
        else if (visible.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyView(
              icon: AurixGlyph.trash,
              title: 'This playlist is empty',
              message: 'There is nothing here to play yet.',
              compact: true,
            ),
          )
        else
          SliverList.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) {
              final item = visible[index];
              final track = item.track;

              if (track == null) {
                return const _UnavailableRow();
              }

              final isCurrent = playback.trackId == track.id;
              return SongTile(
                track: track,
                showAlbumName: true,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playback.isPlaying,
                isSaved: saved.contains(track.id),
                onSaveToggle: () => _toggleTrackSave(track),
                onMore: () => _showTrackMenu(item, index),
                onTap: () => _playFrom(track),
              );
            },
          ),

        // Paging feedback. A spinner only while a page is genuinely in flight,
        // and a one-line notice if Spotify stopped serving pages part-way —
        // silently showing 200 of 3,000 tracks would read as data loss.
        if (_loadingMore)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
              child: Center(
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          )
        else if (_pagingFailed && visible.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.page,
                vertical: AppSpacing.md,
              ),
              child: Text(
                'Spotify stopped sending more of this playlist. Showing the '
                '${visible.length} songs that loaded.',
                style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
                textAlign: TextAlign.center,
              ),
            ),
          ),

        SliverToBoxAdapter(
          child: SizedBox(
            height: shellBottomInset(
              context,
              hasTrack: ref.watch(hasActivePlaybackProvider),
            ),
          ),
        ),
      ],
    );
  }

  // ---- Actions -----------------------------------------------------------

  void _togglePlay() {
    final controller = ref.read(playerControllerProvider.notifier);
    final playback = ref.read(playbackBadgeProvider);

    if (playback.contextUri == _playlist.spotifyUri && playback.hasTrack) {
      controller.togglePlayPause();
      return;
    }
    controller.playPlaylist(_playlist);
  }

  void _shuffle() {
    ref.read(playerControllerProvider.notifier).playPlaylist(_playlist, shuffle: true);
  }

  void _playFrom(Track track) {
    final index = _playableTracks.indexWhere((t) => t.id == track.id);
    ref.read(playerControllerProvider.notifier).playPlaylist(
      _playlist,
      startIndex: index < 0 ? 0 : index,
    );
  }

  Future<void> _toggleSave() async {
    if (_savePending) return;
    // Unknown is treated as not-saved for the *action* only: tapping an
    // indeterminate heart saves. The display stays indeterminate until then,
    // which is the part that must not lie.
    final previous = _isSaved;
    final next = !(previous ?? false);

    setState(() {
      _isSaved = next;
      _savePending = true;
    });

    try {
      final library = ref.read(libraryRepositoryProvider);
      if (next) {
        await library.savePlaylist(_playlist);
      } else {
        await library.unsavePlaylist(_playlist);
      }
      if (!mounted) return;
      AppSnackbar.success(
        context,
        next ? 'Saved to your library' : 'Removed from your library',
      );
    } on Object catch (error) {
      if (!mounted) return;
      // Back to whatever it was, including unknown — inventing `false` here
      // would turn a failed write into a false claim about the library.
      setState(() => _isSaved = previous);
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    } finally {
      if (mounted) setState(() => _savePending = false);
    }
  }

  /// Likes or unlikes a row through the shared store.
  ///
  /// No local state and no invalidation: the store flips the heart optimistically
  /// for every surface at once and rolls back if Spotify refuses, so this only
  /// has to report a failure.
  Future<void> _toggleTrackSave(Track track) async {
    try {
      await ref.read(savedTracksProvider.notifier).toggle(track);
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  /// Removes a track from the playlist.
  ///
  /// Passes the playlist's `snapshot_id` so a concurrent edit from another
  /// device cannot make Spotify delete the wrong row — positions shift, IDs do
  /// not, and the snapshot is what reconciles the two.
  Future<void> _removeTrack(Track track) async {
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Remove from playlist?',
      message: '"${track.name}" will be removed from ${_playlist.name}.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    setState(() => _removing.add(track.id));

    try {
      final snapshot = await ref
          .read(catalogueRepositoryProvider)
          .removeFromPlaylist(
            _playlist.id,
            track,
            snapshotId: _playlist.snapshotId,
          );

      if (!mounted) return;

      setState(() {
        _playlist = _playlist.copyWith(
          snapshotId: snapshot ?? _playlist.snapshotId,
          trackCount: (_playlist.trackCount - 1).clamp(0, 1 << 30),
        );
      });
      AppSnackbar.success(context, 'Removed from playlist');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _removing.remove(track.id));
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  void _share() {
    ShareHelper.share(
      context,
      kind: ShareKind.playlist,
      id: _playlist.id,
      name: _playlist.name,
      subtitle: _playlist.ownerName,
      spotifyUrl: _playlist.spotifyUrl,
    );
  }

  void _showMore() {
    BottomSheetMenu.show(
      context,
      title: _playlist.name,
      subtitle: 'By ${_playlist.ownerName}',
      imageUrl: _playlist.thumbnailUrl,
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add all to queue',
          enabled: _playableTracks.isNotEmpty,
          onTap: () {
            ref.read(playerControllerProvider.notifier).addAllToQueue(_playableTracks);
            AppSnackbar.success(
              context,
              'Added ${_playableTracks.length} songs to queue',
            );
          },
        ),
        SheetAction(
          icon: AurixGlyph.share,
          label: 'Share',
          onTap: _share,
        ),
      ],
    );
  }

  void _showTrackMenu(PlaylistItem item, int index) {
    final track = item.track;
    if (track == null) return;

    final controller = ref.read(playerControllerProvider.notifier);
    final artist = track.primaryArtist;

    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl,
      note: item.addedAt == null
          ? null
          : 'Added ${Formatters.relativeTime(item.addedAt!)}',
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Play next',
          onTap: () {
            controller.playNextInQueue(track);
            AppSnackbar.success(context, 'Playing next');
          },
        ),
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add to queue',
          onTap: () {
            controller.addToQueue(track);
            AppSnackbar.success(context, 'Added to queue');
          },
        ),
        if (artist != null)
          SheetAction(
            icon: AurixGlyph.profile,
            label: 'Go to artist',
            onTap: () => context.pushDistinct(
              RouteNames.artist,
              pathParameters: {'id': artist.id},
            ),
          ),
        if (track.album != null)
          SheetAction(
            icon: AurixGlyph.album,
            label: 'Go to album',
            onTap: () => context.pushDistinct(
              RouteNames.album,
              pathParameters: {'id': track.album!.id},
            ),
          ),
        SheetAction(
          icon: AurixGlyph.share,
          label: 'Share song',
          onTap: () => ShareHelper.share(
            context,
            kind: ShareKind.track,
            id: track.id,
            name: track.name,
            subtitle: track.artistNames,
            spotifyUrl: track.spotifyUrl,
          ),
        ),
        // Only shown when Spotify would actually accept the write.
        if (widget.detail.isEditable)
          SheetAction(
            icon: AurixGlyph.close,
            label: 'Remove from this playlist',
            destructive: true,
            onTap: () => _removeTrack(track),
          ),
      ],
    );
  }
}

/// A row Spotify returned with no track — removed from the catalogue, or a
/// local file the API cannot describe. Rendering it keeps the numbering honest
/// instead of silently shortening the list.
class _UnavailableRow extends StatelessWidget {
  const _UnavailableRow();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: AppSizes.tileArtworkLarge,
            height: AppSizes.tileArtworkLarge,
            decoration: BoxDecoration(
              color: context.palette.artworkPlaceholder,
              borderRadius: const BorderRadius.all(Radius.circular(AppRadius.xs)),
            ),
            child: AurixIcon(
              AurixGlyph.block,
              size: 20,
              color: context.palette.textTertiary,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Unavailable track',
                  style: AppTypography.titleMedium.copyWith(
                    color: context.palette.textTertiary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Removed from Spotify, or a local file',
                  style: AppTypography.bodySmall.copyWith(
                    color: context.palette.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Loading extends StatelessWidget {
  const _Loading({required this.reduceMotion});

  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              onPressed: () => context.pop(),
              icon: const AurixIcon(AurixGlyph.back),
              tooltip: 'Back',
            ),
          ),
          SkeletonDetailHeader(animate: !reduceMotion),
          Expanded(
            child: SingleChildScrollView(
              child: SkeletonTrackList(itemCount: 8, animate: !reduceMotion),
            ),
          ),
        ],
      ),
    );
  }
}
