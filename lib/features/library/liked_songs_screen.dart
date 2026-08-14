import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/network/error_mapper.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/aurix_palette.dart';
import '../../core/utils/album_palette.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/responsive.dart';
import '../../data/models/track.dart';
import '../../playback/playback_queue.dart';
import '../../playback/player_controller.dart';
import '../../shared/widgets/feedback/app_snackbar.dart';
import '../../shared/widgets/feedback/loading_skeleton.dart';
import '../../shared/widgets/feedback/state_views.dart';
import '../../shared/widgets/icons/aurix_glyphs.dart';
import '../../shared/widgets/icons/aurix_icon.dart';
import '../../shared/widgets/layout/detail_action_bar.dart';
import '../../shared/widgets/layout/gradient_header.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/library_provider.dart';
import 'providers/saved_tracks_provider.dart';

/// Liked Songs — the one playlist every account has.
///
/// Read as one live Firestore query. It used to be paged, because liked songs
/// lived behind `/me/tracks` and that endpoint returns 50 at a time; the
/// collection is the user's own now, and comes off the local cache at once.
class LikedSongsScreen extends ConsumerStatefulWidget {
  const LikedSongsScreen({super.key});

  @override
  ConsumerState<LikedSongsScreen> createState() => _LikedSongsScreenState();
}

class _LikedSongsScreenState extends ConsumerState<LikedSongsScreen> {
  final ScrollController _scrollController = ScrollController();

  /// A synthetic header tone stands in for artwork — Liked Songs has none.
  ///
  /// Built through [AlbumPalette.fromLuminance] rather than by hand so it lands
  /// in exactly the band a sampled cover would, and so it reflects into the
  /// light theme by the same rule as every real header. Hand-mixing a colour
  /// here is how this screen previously ended up as the one header in the app
  /// that ignored the theme.
  ///
  /// 0.72 is a deliberately bright input: the tile below it is the app's one
  /// inverted, near-white artwork, and a dark header under a white cover looks
  /// like the gradient failed to load.
  AlbumPalette _paletteOf(BuildContext context) =>
      AlbumPalette.fromLuminance(0.72);

  // There is no scroll listener and no `loadMore` here any more.
  //
  // Liked songs came from `/me/tracks`, which pages at 50, so this screen
  // carried a paging controller and fetched the next page whenever the user
  // scrolled within 600px of the bottom. The collection is a Firestore query
  // now: one subscription, served from the local cache, delivering the list.

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final liked = ref.watch(likedSongsProvider);

    // No seeding step either. The old implementation pushed every row on this
    // screen into the shared saved-track store, so a track seen here showed a
    // filled heart when it appeared in a playlist later without another
    // `contains` request. Both screens read the same live collection now, so
    // there is nothing to reconcile.

    // The badge, not the whole state: this screen renders a list that can hold
    // thousands of rows and reads no position, so watching the full state
    // rebuilt the entire `CustomScrollView` — and the O(n) duration fold below
    // — twice a second for as long as anything played.
    final playback = ref.watch(playbackBadgeProvider);

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: liked.when(
        data: (saved) => _content(saved, playback),
        loading: () => SafeArea(
          child: Column(
            children: [
              _backBar(),
              SkeletonDetailHeader(
                animate: !ref.watch(reduceMotionProvider),
              ),
              Expanded(
                child: SingleChildScrollView(
                  child: SkeletonTrackList(
                    itemCount: 8,
                    animate: !ref.watch(reduceMotionProvider),
                  ),
                ),
              ),
            ],
          ),
        ),
        error: (error, _) => SafeArea(
          child: Column(
            children: [
              _backBar(),
              Expanded(
                child: ErrorView(
                  error: ErrorMapper.fromUnknown(error),
                  onRetry: () => ref.invalidate(likedSongsProvider),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _backBar() => Align(
    alignment: Alignment.centerLeft,
    child: IconButton(
      onPressed: () => context.pop(),
      icon: const AurixIcon(AurixGlyph.back),
      tooltip: 'Back',
    ),
  );

  Widget _content(List<Track> saved, PlaybackBadge playback) {
    if (saved.isEmpty) {
      return SafeArea(
        child: Column(
          children: [
            _backBar(),
            const Expanded(
              child: EmptyView(
                icon: AurixGlyph.heart,
                title: 'No liked songs yet',
                message: 'Tap the heart on any song and it shows up here.',
              ),
            ),
          ],
        ),
      );
    }

    final tracks = saved;
    const contextUri = 'aurix:liked-songs';
    final isPlayingHere = playback.contextUri == contextUri;

    final totalDuration = tracks.fold<Duration>(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ImmersiveHeader(
          title: 'Liked Songs',
          overline: 'Playlist',
          palette: _paletteOf(context),
          artwork: Container(
            width: context.responsive(compact: 180, medium: 200, expanded: 220),
            height: context.responsive(compact: 180, medium: 200, expanded: 220),
            decoration: BoxDecoration(
              borderRadius: AppRadius.card,
              // The inverted Liked Songs tile at hero scale — see the matching
              // note in `library_rows.dart`. Both have to agree, because this
              // is the same collection the user just tapped in the library.
              gradient: LinearGradient(
                colors: [
                  context.palette.accent,
                  Color.lerp(
                    context.palette.accent,
                    context.palette.textSecondary,
                    0.5,
                  )!,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 26,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: AurixIcon(
              AurixGlyph.heartFilled,
              size: 64,
              color: context.palette.textOnAccent,
            ),
          ),
          metadata: MetadataStrip(
            parts: <String>[
              '${Formatters.groupedNumber(saved.length)} '
                  '${saved.length == 1 ? 'song' : 'songs'}'
,
              Formatters.longDuration(totalDuration),
            ],
          ),
        ),

        SliverToBoxAdapter(
          child: DetailActionBar(
            isPlaying: isPlayingHere && playback.isPlaying,
            isShuffled: isPlayingHere && playback.shuffled,
            onPlay: () => _play(tracks, contextUri),
            onShuffle: () => _play(tracks, contextUri, shuffle: true),
            onMore: () => _showMore(tracks),
          ),
        ),

        SliverList.builder(
          itemCount: saved.length,
          itemBuilder: (context, index) {
            final track = saved[index];
            final isCurrent = playback.trackId == track.id;
            return SongTile(
              track: track,
              showAlbumName: true,
              isCurrent: isCurrent,
              isPlaying: isCurrent && playback.isPlaying,
              // Every track here is liked by definition — the heart is always
              // filled, and tapping it removes the track from this list.
              isSaved: true,
              onSaveToggle: () => _unlike(track),
              onTap: () => _play(tracks, contextUri, startIndex: index),
              onMore: () => _showTrackMenu(track),
            );
          },
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

  void _play(
    List<Track> tracks,
    String contextUri, {
    int startIndex = 0,
    bool shuffle = false,
  }) {
    ref.read(playerControllerProvider.notifier).playTracks(
      tracks,
      startIndex: startIndex,
      shuffle: shuffle,
      context: PlaybackContext(
        title: 'Liked Songs',
        subtitle: 'Your library',
        uri: contextUri,
      ),
    );
  }

  /// Removes a track from Liked Songs.
  ///
  /// No invalidation of anything. The write goes to Firestore, the same
  /// collection this list is a view of, so the row leaves on the next snapshot
  /// — which Firestore emits from its local cache before the write has even
  /// reached the network. Every other surface showing that heart follows for
  /// the same reason.
  Future<void> _unlike(Track track) async {
    try {
      await ref
          .read(likedTracksControllerProvider.notifier)
          .setLiked(track, liked: false);
      if (!mounted) return;
      AppSnackbar.undoable(
        context,
        'Removed from Liked Songs',
        onUndo: () => _relike(track),
      );
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  Future<void> _relike(Track track) async {
    try {
      await ref
          .read(likedTracksControllerProvider.notifier)
          .setLiked(track, liked: true);
    } on Object {
      // The undo failed; the snackbar has already gone. The stream is still
      // the truth, so the screen remains honest either way.
    }
  }

  void _showMore(List<Track> tracks) {
    BottomSheetMenu.show(
      context,
      title: 'Liked Songs',
      subtitle: '${tracks.length} songs',
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add all to queue',
          onTap: () {
            ref.read(playerControllerProvider.notifier).addAllToQueue(tracks);
            AppSnackbar.success(context, 'Added ${tracks.length} songs to queue');
          },
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
          onTap: () => controller.playNextInQueue(track),
        ),
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add to queue',
          onTap: () => controller.addToQueue(track),
        ),
        SheetAction(
          icon: AurixGlyph.heart,
          label: 'Remove from Liked Songs',
          destructive: true,
          onTap: () => _unlike(track),
        ),
      ],
    );
  }
}
