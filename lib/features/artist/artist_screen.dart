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
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../core/utils/share_helper.dart';
import '../../data/models/album.dart';
import '../../data/models/artist.dart';
import '../../data/models/track.dart';
import '../../data/repositories/catalogue_repository.dart';
import '../../playback/playback_queue.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/controls/play_button.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/layout/detail_action_bar.dart';
import '../../shared/widgets/layout/gradient_header.dart';
import '../../shared/widgets/layout/section_header.dart';
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/media/content_cards.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../album/providers/detail_providers.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';

/// Artist detail.
class ArtistScreen extends ConsumerWidget {
  const ArtistScreen({required this.artistId, super.key});

  final String artistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(artistDetailProvider(artistId));

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: detail.when(
        data: (data) => _ArtistContent(detail: data),
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
                  onRetry: () => ref.invalidate(artistDetailProvider(artistId)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ArtistContent extends ConsumerStatefulWidget {
  const _ArtistContent({required this.detail});

  final ArtistDetail detail;

  @override
  ConsumerState<_ArtistContent> createState() => _ArtistContentState();
}

class _ArtistContentState extends ConsumerState<_ArtistContent> {
  late bool _isFollowed = widget.detail.isFollowed;
  bool _followPending = false;

  /// "Popular tracks" starts collapsed at five rows; ten is a wall of text
  /// before the discography anyone came for.
  bool _showAllTopTracks = false;

  Artist get _artist => widget.detail.artist;
  List<Track> get _topTracks => widget.detail.topTracks;

  @override
  void initState() {
    super.initState();
    ref.read(albumPaletteServiceProvider).resolve(_artist.imageUrl);
  }

  @override
  Widget build(BuildContext context) {
    final palette = watchPalette(ref, _artist.imageUrl);
    // The badge, not the whole state — the track list here reads no position,
    // and watching the full state rebuilt every row twice a second.
    final playback = ref.watch(playbackBadgeProvider);
    final isThisArtistPlaying = playback.contextUri == _artist.spotifyUri;

    final visibleTop =
        _showAllTopTracks ? _topTracks : _topTracks.take(5).toList();

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ImmersiveHeader(
          title: _artist.name,
          palette: palette,
          centerArtwork: false,
          blurArtwork: true,
          expandedHeight: context.responsive(compact: 300, medium: 340, expanded: 380),
          artwork: AppArtwork(
            imageUrl: _artist.imageUrl,
            size: context.screenWidth,
            borderRadius: BorderRadius.zero,
            seed: _artist.id,
            heroTag: 'artist-${_artist.id}',
          ),
          metadata: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_artist.isHighProfile) ...[
                const _PopularArtistBadge(),
                const SizedBox(width: AppSpacing.sm),
              ],
              if (_artist.followers != null)
                Text(
                  '${Formatters.compactNumber(_artist.followers!)} followers',
                  style: AppTypography.bodySmall.copyWith(
                    color: context.palette.textPrimary.withValues(alpha: 0.78),
                  ),
                ),
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

        SliverToBoxAdapter(
          child: DetailActionBar(
            isPlaying: isThisArtistPlaying && playback.isPlaying,
            isShuffled: isThisArtistPlaying && playback.shuffled,
            playEnabled: _topTracks.isNotEmpty,
            onPlay: _togglePlay,
            onShuffle: _shuffle,
            onShare: _share,
            onMore: _showMore,
            leadingExtra: ActionPill(
              label: _isFollowed ? 'Following' : 'Follow',
              icon: _isFollowed ? AurixGlyph.check : AurixGlyph.add,
              selected: _isFollowed,
              enabled: !_followPending,
              onPressed: _toggleFollow,
            ),
          ),
        ),

        if (_artist.genres.isNotEmpty)
          SliverToBoxAdapter(child: _GenreChips(genres: _artist.genres)),

        // ---- Popular tracks -------------------------------------------
        if (visibleTop.isNotEmpty) ...[
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.only(top: AppSpacing.lg),
              child: SectionHeader(title: 'Popular'),
            ),
          ),
          SliverList.builder(
            itemCount: visibleTop.length,
            itemBuilder: (context, index) {
              final track = visibleTop[index];
              final isCurrent = playback.trackId == track.id;
              return SongTile(
                track: track,
                variant: SongTileVariant.compact,
                index: index + 1,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playback.isPlaying,
                onMore: () => _showTrackMenu(track),
                onTap: () => _playTopTrack(index),
              );
            },
          ),
          if (_topTracks.length > 5)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.page,
                  top: AppSpacing.sm,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllTopTracks = !_showAllTopTracks),
                    style: TextButton.styleFrom(
                      foregroundColor: context.palette.textSecondary,
                    ),
                    child: Text(_showAllTopTracks ? 'Show less' : 'See more'),
                  ),
                ),
              ),
            ),
        ],

        // ---- Discography ------------------------------------------------
        _albumShelf('Albums', widget.detail.albums, showYear: true),
        _albumShelf('Singles & EPs', widget.detail.singles, showYear: true),
        _albumShelf('Appears on', widget.detail.appearsOn),

        // ---- Related ------------------------------------------------------
        if (widget.detail.relatedArtists.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
              child: ShelfSection(
                title: 'Fans also like',
                itemCount: widget.detail.relatedArtists.length,
                itemHeight: context.carouselCardWidth + 58,
                itemBuilder: (context, index) {
                  final related = widget.detail.relatedArtists[index];
                  return ArtistCard(
                    artist: related,
                    width: context.carouselCardWidth,
                    onTap: () => context.pushReplacementNamed(
                      RouteNames.artist,
                      pathParameters: {'id': related.id},
                    ),
                  );
                },
              ),
            ),
          ),

        SliverToBoxAdapter(
          child: SizedBox(
            height: shellBottomInset(
                  context,
                  hasTrack: ref.watch(hasActivePlaybackProvider),
                ) +
                AppSpacing.xl,
          ),
        ),
      ],
    );
  }

  Widget _albumShelf(String title, List<Album> albums, {bool showYear = false}) {
    if (albums.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.only(top: AppSpacing.sectionGap),
        child: ShelfSection(
          title: title,
          itemCount: albums.length,
          itemHeight: context.carouselCardWidth + 58,
          itemBuilder: (context, index) {
            final album = albums[index];
            return AlbumCard(
              album: album,
              width: context.carouselCardWidth,
              showYear: showYear,
              onTap: () => context.pushDistinct(
                RouteNames.album,
                pathParameters: {'id': album.id},
              ),
            );
          },
        ),
      ),
    );
  }

  // ---- Actions -----------------------------------------------------------

  PlaybackContext get _context => PlaybackContext(
    title: _artist.name,
    subtitle: 'Popular tracks',
    uri: _artist.spotifyUri,
    imageUrl: _artist.imageUrl,
  );

  void _togglePlay() {
    final controller = ref.read(playerControllerProvider.notifier);
    final playback = ref.read(playbackBadgeProvider);

    if (playback.contextUri == _artist.spotifyUri && playback.hasTrack) {
      controller.togglePlayPause();
      return;
    }
    controller.playTracks(_topTracks, context: _context);
  }

  void _shuffle() {
    ref.read(playerControllerProvider.notifier).playTracks(
      _topTracks,
      shuffle: true,
      context: _context,
    );
  }

  void _playTopTrack(int index) {
    ref.read(playerControllerProvider.notifier).playTracks(
      _topTracks,
      startIndex: index,
      context: _context,
    );
  }

  Future<void> _toggleFollow() async {
    if (_followPending) return;
    final next = !_isFollowed;

    setState(() {
      _isFollowed = next;
      _followPending = true;
    });

    try {
      final library = ref.read(libraryRepositoryProvider);
      if (next) {
        await library.followArtist(_artist);
      } else {
        await library.unfollowArtist(_artist);
      }
      if (!mounted) return;
      AppSnackbar.success(
        context,
        next ? 'Following ${_artist.name}' : 'Unfollowed ${_artist.name}',
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _isFollowed = !next);
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    } finally {
      if (mounted) setState(() => _followPending = false);
    }
  }

  void _share() {
    ShareHelper.share(
      context,
      kind: ShareKind.artist,
      id: _artist.id,
      name: _artist.name,
      spotifyUrl: _artist.spotifyUrl,
    );
  }

  void _showMore() {
    BottomSheetMenu.show(
      context,
      title: _artist.name,
      subtitle: 'Artist',
      imageUrl: _artist.avatarUrl,
      imageShape: ArtworkShape.circle,
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Queue popular tracks',
          enabled: _topTracks.isNotEmpty,
          onTap: () {
            ref.read(playerControllerProvider.notifier).addAllToQueue(_topTracks);
            AppSnackbar.success(context, 'Added ${_topTracks.length} songs to queue');
          },
        ),
        SheetAction(
          icon: _isFollowed ? AurixGlyph.profile : AurixGlyph.profile,
          label: _isFollowed ? 'Unfollow' : 'Follow',
          onTap: _toggleFollow,
        ),
        SheetAction(
          icon: AurixGlyph.share,
          label: 'Share',
          onTap: _share,
        ),
      ],
    );
  }

  void _showTrackMenu(Track track) {
    final controller = ref.read(playerControllerProvider.notifier);
    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl,
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
        if (track.album != null)
          SheetAction(
            icon: AurixGlyph.album,
            label: 'Go to album',
            onTap: () => context.pushDistinct(
              RouteNames.album,
              pathParameters: {'id': track.album!.id},
            ),
          ),
      ],
    );
  }
}

/// Spotify's Web API exposes no "verified" flag, so AURIX marks high
/// popularity instead of implying a verification Spotify never asserted.
class _PopularArtistBadge extends StatelessWidget {
  const _PopularArtistBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 3),
      decoration: BoxDecoration(
        color: context.palette.accent,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AurixIcon(AurixGlyph.trending, size: 12, color: context.palette.textOnAccent),
          const SizedBox(width: 3),
          Text(
            'Popular artist',
            style: AppTypography.labelSmall.copyWith(
              color: context.palette.textOnAccent,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

class _GenreChips extends StatelessWidget {
  const _GenreChips({required this.genres});

  final List<String> genres;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.page,
        vertical: AppSpacing.sm,
      ),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final genre in genres.take(5))
            Chip(
              label: Text(Formatters.titleCaseGenre(genre)),
              backgroundColor: context.palette.surfaceElevated,
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
          SkeletonDetailHeader(artworkSize: 150, animate: !reduceMotion),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  SkeletonTrackList(itemCount: 4, animate: !reduceMotion),
                  const SizedBox(height: AppSpacing.xl),
                  SkeletonShelf(
                    cardWidth: context.carouselCardWidth,
                    animate: !reduceMotion,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
