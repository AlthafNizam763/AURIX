import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
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
import '../library/providers/saved_tracks_provider.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/detail_providers.dart';

/// Album detail.
class AlbumScreen extends ConsumerWidget {
  const AlbumScreen({required this.albumId, super.key});

  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(albumDetailProvider(albumId));

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: detail.when(
        data: (data) => _AlbumContent(detail: data),
        loading: () => _Loading(reduceMotion: ref.watch(reduceMotionProvider)),
        error: (error, _) => SafeArea(
          child: Column(
            children: [
              const _BackBar(),
              Expanded(
                child: ErrorView(
                  error: ErrorMapper.fromUnknown(error),
                  onRetry: () => ref.invalidate(albumDetailProvider(albumId)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlbumContent extends ConsumerStatefulWidget {
  const _AlbumContent({required this.detail});

  final AlbumDetail detail;

  @override
  ConsumerState<_AlbumContent> createState() => _AlbumContentState();
}

class _AlbumContentState extends ConsumerState<_AlbumContent> {
  late bool _isSaved = widget.detail.isSaved;
  bool _savePending = false;

  Album get _album => widget.detail.album;
  List<Track> get _tracks => widget.detail.tracks;

  @override
  void initState() {
    super.initState();
    // Extraction is async and cached; kicking it off here means the gradient
    // is usually ready by the time the header finishes its entrance.
    ref.read(albumPaletteServiceProvider).resolve(_album.imageUrl);
    _requestSavedState();
  }

  @override
  void didUpdateWidget(_AlbumContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.detail.album.id != _album.id) _requestSavedState();
  }

  /// Asks the shared store about this album's tracks, once.
  ///
  /// From the lifecycle rather than from `build` — a membership lookup fired
  /// during the build phase is a side effect in the one place Flutter cannot
  /// tolerate one. The store batches and de-duplicates, so tracks already
  /// answered for on another screen cost nothing here.
  void _requestSavedState() {
    ref
        .read(savedTracksProvider.notifier)
        .ensureKnown(_tracks.map((t) => t.id));
  }

  @override
  Widget build(BuildContext context) {
    final palette = watchPalette(ref, _album.imageUrl);

    // The badge, not the whole state — the track list here reads no position,
    // and watching the full state rebuilt every row twice a second.
    final playback = ref.watch(playbackBadgeProvider);
    final isThisAlbumPlaying = playback.contextUri == _album.spotifyUri;

    // One shared answer for the whole app, so a heart filled in the player is
    // already filled when the user comes back to this list.
    final saved = ref.watch(savedTracksProvider);

    // Multi-disc albums get disc headers; single-disc ones must not.
    final discCount = _tracks.isEmpty
        ? 1
        : _tracks.map((t) => t.discNumber).toSet().length;

    return CustomScrollView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ImmersiveHeader(
          title: _album.name,
          overline: _album.albumType.label,
          subtitle: _album.artistNames,
          palette: palette,
          artwork: AppArtwork(
            imageUrl: _album.imageUrl,
            size: context.responsive(compact: 196, medium: 220, expanded: 240),
            seed: _album.id,
            elevated: true,
            heroTag: 'album-${_album.id}',
          ),
          metadata: MetadataStrip(
            parts: <String>[
              Formatters.releaseYear(_album.releaseDate),
              '${_album.totalTracks} ${_album.totalTracks == 1 ? 'song' : 'songs'}',
              if (_album.totalDuration != null)
                Formatters.longDuration(_album.totalDuration!),
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
            isPlaying: isThisAlbumPlaying && playback.isPlaying,
            isShuffled: isThisAlbumPlaying && playback.shuffled,
            isSaved: _isSaved,
            playEnabled: _tracks.isNotEmpty,
            isLoading: _savePending && _tracks.isEmpty,
            onPlay: _togglePlay,
            onShuffle: _shuffle,
            onSaveToggle: _toggleSave,
            saveTooltip: _isSaved ? 'Remove from your albums' : 'Save album',
            onShare: _share,
            onMore: _showMore,
          ),
        ),

        if (widget.detail.isStale)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.page),
              child: _OfflineNote(),
            ),
          ),

        if (_tracks.isEmpty)
          const SliverToBoxAdapter(
            child: EmptyView(
              icon: AurixGlyph.block,
              title: 'No tracks',
              message: 'Spotify returned no playable tracks for this album.',
              compact: true,
            ),
          )
        else
          SliverList.builder(
            itemCount: _tracks.length,
            itemBuilder: (context, index) {
              final track = _tracks[index];
              final isCurrent = playback.trackId == track.id;

              final showDiscHeader = discCount > 1 &&
                  (index == 0 || _tracks[index - 1].discNumber != track.discNumber);

              final tile = SongTile(
                track: track,
                variant: SongTileVariant.numbered,
                index: track.trackNumber == 0 ? index + 1 : track.trackNumber,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playback.isPlaying,
                isSaved: saved.contains(track.id),
                onSaveToggle: () => _toggleTrackSave(track),
                onMore: () => _showTrackMenu(track),
                onTap: () => _playFrom(index),
              );

              if (!showDiscHeader) return tile;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.page,
                      AppSpacing.lg,
                      AppSpacing.page,
                      AppSpacing.sm,
                    ),
                    child: Text(
                      'Disc ${track.discNumber}',
                      style: AppTypography.overline,
                    ),
                  ),
                  tile,
                ],
              );
            },
          ),

        SliverToBoxAdapter(child: _Credits(album: _album)),

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

    if (playback.contextUri == _album.spotifyUri && playback.hasTrack) {
      controller.togglePlayPause();
      return;
    }
    controller.playAlbum(_album);
  }

  void _shuffle() {
    ref.read(playerControllerProvider.notifier).playAlbum(_album, shuffle: true);
  }

  void _playFrom(int index) {
    ref.read(playerControllerProvider.notifier).playAlbum(_album, startIndex: index);
  }

  Future<void> _toggleSave() async {
    if (_savePending) return;
    final next = !_isSaved;

    // Optimistic: the button flips immediately and reverts if the write fails.
    setState(() {
      _isSaved = next;
      _savePending = true;
    });

    try {
      final library = ref.read(libraryRepositoryProvider);
      if (next) {
        await library.saveAlbum(_album);
      } else {
        await library.unsaveAlbum(_album);
      }
      if (!mounted) return;
      AppSnackbar.success(
        context,
        next ? 'Saved to your albums' : 'Removed from your albums',
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _isSaved = !next);
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

  void _share() {
    ShareHelper.share(
      context,
      kind: ShareKind.album,
      id: _album.id,
      name: _album.name,
      subtitle: _album.artistNames,
      spotifyUrl: _album.spotifyUrl,
    );
  }

  void _showMore() {
    final artist = _album.primaryArtist;
    BottomSheetMenu.show(
      context,
      title: _album.name,
      subtitle: _album.artistNames,
      imageUrl: _album.thumbnailUrl,
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add all to queue',
          enabled: _tracks.isNotEmpty,
          onTap: () {
            ref.read(playerControllerProvider.notifier).addAllToQueue(_tracks);
            AppSnackbar.success(context, 'Added ${_tracks.length} songs to queue');
          },
        ),
        if (artist != null)
          SheetAction(
            icon: AurixGlyph.profile,
            label: 'Go to ${artist.name}',
            onTap: () => context.pushDistinct(
              RouteNames.artist,
              pathParameters: {'id': artist.id},
            ),
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
    final artist = track.primaryArtist;
    final controller = ref.read(playerControllerProvider.notifier);

    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl ?? _album.thumbnailUrl,
      note: track.hasPreview
          ? null
          : 'Spotify provides no 30-second preview for this track. It plays in '
              'full only through a Spotify Connect device.',
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
      ],
    );
  }
}

/// Label and copyright lines, as Spotify supplies them.
class _Credits extends StatelessWidget {
  const _Credits({required this.album});

  final Album album;

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      Formatters.releaseDate(album.releaseDate, album.releaseDatePrecision),
      if (album.label != null) album.label!,
      ...album.copyrights,
    ].where((line) => line.isNotEmpty).toList();

    if (lines.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.page,
        AppSpacing.xxl,
        AppSpacing.page,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                line,
                style: AppTypography.bodySmall.copyWith(
                  fontSize: 11,
                  color: context.palette.textTertiary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _OfflineNote extends StatelessWidget {
  const _OfflineNote();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        children: [
          AurixIcon(AurixGlyph.offline, size: 14, color: context.palette.textTertiary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              'Offline — showing saved details.',
              style: AppTypography.bodySmall.copyWith(fontSize: 11.5),
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
          const _BackBar(),
          SkeletonDetailHeader(animate: !reduceMotion),
          Expanded(
            child: SingleChildScrollView(
              child: SkeletonTrackList(itemCount: 8, animate: !reduceMotion),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(duration: const Duration(milliseconds: 180));
  }
}

class _BackBar extends StatelessWidget {
  const _BackBar();

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: IconButton(
        onPressed: () => context.pop(),
        icon: const AurixIcon(AurixGlyph.back),
        tooltip: 'Back',
      ),
    );
  }
}
