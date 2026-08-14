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
import '../../data/import/music_import_provider.dart';
import '../../data/models/playlist.dart';
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
import '../../shared/widgets/media/app_artwork.dart';
import '../../shared/widgets/media/song_tile.dart';
import '../../shared/widgets/sheets/bottom_sheet_menu.dart';
import '../album/providers/detail_providers.dart';
import '../auth/providers/auth_provider.dart';
import '../import/providers/playlist_import_provider.dart';
import '../library/providers/saved_tracks_provider.dart';
import '../settings/providers/settings_provider.dart';
import '../shell/app_shell.dart';
import 'providers/playlist_providers.dart';
import 'widgets/playlist_edit_sheets.dart';

/// Playlist detail.
///
/// ## What changed under this screen
///
/// The contents used to arrive from `GET /playlists/{id}/items`, 100 rows at a
/// time, so the widget held the playlist in local state, appended pages on
/// scroll, tracked a `_pagingFailed` flag for the case where Spotify stopped
/// serving part-way through, and threaded a `snapshot_id` through every edit so
/// a concurrent change on another device could not make Spotify delete the
/// wrong row.
///
/// All of it is gone. The playlist is a Firestore document with a `tracks`
/// subcollection, watched as one stream: edits appear as they land, from any
/// device, and Firestore's transactions do what the snapshot token was for.
class PlaylistScreen extends ConsumerWidget {
  const PlaylistScreen({required this.playlistId, super.key});

  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(aurixPlaylistProvider(playlistId));

    return Scaffold(
      backgroundColor: context.palette.ground,
      body: detail.when(
        data: (data) => data == null
            ? const _Missing()
            : _PlaylistContent(detail: data),
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
                child: ErrorView(error: ErrorMapper.fromUnknown(error)),
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

  final AurixPlaylistDetail detail;

  @override
  ConsumerState<_PlaylistContent> createState() => _PlaylistContentState();
}

class _PlaylistContentState extends ConsumerState<_PlaylistContent> {
  final ScrollController _scrollController = ScrollController();

  /// True while a drag-to-reorder is on screen.
  ///
  /// Reordering swaps the list for a `ReorderableListView`, which cannot live
  /// inside a `CustomScrollView` of slivers — and, more importantly, must not
  /// be rebuilt underneath the user by an incoming snapshot mid-drag.
  bool _reordering = false;

  /// The order as the user is arranging it, while [_reordering].
  ///
  /// Held locally so a drag is smooth: each drop writes one document and the
  /// stream echoes it back, but the list must move on the frame of the drop
  /// rather than on the frame the echo arrives.
  List<Track>? _draftOrder;

  Playlist get _playlist => widget.detail.playlist;
  List<Track> get _tracks => _draftOrder ?? widget.detail.tracks;

  /// Whether this account may change the playlist.
  ///
  /// False on a catalogue playlist somebody else imported: it is fully
  /// readable and playable, and the controls that would change it for every
  /// other user are withheld rather than offered and refused. See
  /// [AurixPlaylistDetail.isEditable].
  bool get _isEditable => widget.detail.isEditable;

  @override
  void initState() {
    super.initState();
    ref.read(albumPaletteServiceProvider).resolve(_playlist.imageUrl);
  }

  @override
  void didUpdateWidget(_PlaylistContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A snapshot arriving while the user is not dragging replaces the draft;
    // one arriving mid-drag is ignored until the drag ends, or the rows would
    // jump under their finger.
    if (!_reordering) _draftOrder = null;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = watchPalette(ref, _playlist.imageUrl);
    // The badge, not the whole state — the track list here reads no position,
    // and watching the full state rebuilt every row twice a second.
    final playback = ref.watch(playbackBadgeProvider);
    final contextUri = _contextUri;
    final isThisPlaylistPlaying = playback.contextUri == contextUri;

    final description = Formatters.plainText(_playlist.description);
    final tracks = _tracks;

    // One shared answer for the whole app, so a heart filled in the player is
    // already filled when the user comes back to this list.
    final liked = ref.watch(likedTracksControllerProvider);

    return CustomScrollView(
      controller: _scrollController,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: [
        ImmersiveHeader(
          title: _playlist.name,
          overline: _playlist.source.isImported
              ? 'Imported from ${_playlist.source.label}'
              : 'Playlist',
          // Credits the AURIX listener who brought a shared playlist in, and
          // falls back to the source for everything else. On a catalogue
          // playlist the interesting fact is that somebody else added it —
          // the service it came from is already on the line above.
          subtitle: _playlist.importCredit ?? 'By ${_playlist.ownerName}',
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
              '${tracks.length} ${tracks.length == 1 ? 'song' : 'songs'}',
              if (widget.detail.totalDuration > Duration.zero)
                Formatters.longDuration(widget.detail.totalDuration),
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
            // No save control. "Saving" a playlist was Spotify's *follow*, for
            // playlists belonging to other people. Everything here is the
            // user's own, and you do not follow what you own.
            playEnabled: tracks.isNotEmpty,
            onPlay: _togglePlay,
            onShuffle: _shuffle,
            onShare: _share,
            onMore: _showMore,
          ),
        ),

        if (tracks.isEmpty)
          SliverToBoxAdapter(
            child: EmptyView(
              icon: AurixGlyph.musicNote,
              title: 'This playlist is empty',
              message: _isEditable
                  ? 'Add songs from anywhere in AURIX — tap ⋯ on a song and '
                        'choose "Add to playlist".'
                  : 'Nothing here yet. Whoever added this playlist can sync it '
                        'to pull its songs in.',
              compact: true,
              actionLabel: 'Find music',
              onAction: () => context.goNamed(RouteNames.search),
            ),
          )
        else if (_reordering)
          SliverReorderableList(
            itemCount: tracks.length,
            onReorder: _onReorder,
            itemBuilder: (context, index) {
              final track = tracks[index];
              return ReorderableDragStartListener(
                // Keyed on the document id, which is stable across a reorder.
                // Keying on the index would make Flutter reuse the wrong row's
                // state as items move.
                key: ValueKey<String>(track.documentId),
                index: index,
                child: SongTile(
                  track: track,
                  showAlbumName: false,
                  // Inert while reordering: the row is a drag handle, not a
                  // button, and a tap that started a drag must not also start
                  // playback.
                  onTap: () {},
                  trailing: AurixIcon(
                    AurixGlyph.dragHandle,
                    size: 20,
                    color: context.palette.textTertiary,
                  ),
                ),
              );
            },
          )
        else
          SliverList.builder(
            itemCount: tracks.length,
            itemBuilder: (context, index) {
              final track = tracks[index];
              final isCurrent = playback.trackId == track.id;
              return SongTile(
                track: track,
                showAlbumName: true,
                isCurrent: isCurrent,
                isPlaying: isCurrent && playback.isPlaying,
                isSaved: liked.contains(track.documentId),
                onSaveToggle: () => _toggleTrackLike(track),
                onMore: () => _showTrackMenu(track),
                onTap: () => _playFrom(index),
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

  /// What the player records as "where this is playing from".
  ///
  /// An AURIX URI rather than a Spotify one: the playlist is a Firestore
  /// document, and `spotify:playlist:<firestore id>` addresses nothing. The
  /// player only compares this against itself, so any stable string works —
  /// what matters is that two different playlists never produce the same one.
  String get _contextUri => 'aurix:playlist:${_playlist.id}';

  PlaybackContext get _playbackContext => PlaybackContext(
    title: _playlist.name,
    subtitle: _playlist.ownerName,
    uri: _contextUri,
  );

  // ---- Playback ----------------------------------------------------------

  void _togglePlay() {
    final controller = ref.read(playerControllerProvider.notifier);
    final playback = ref.read(playbackBadgeProvider);

    if (playback.contextUri == _contextUri && playback.hasTrack) {
      controller.togglePlayPause();
      return;
    }
    controller.playTracks(_tracks, context: _playbackContext);
  }

  void _shuffle() {
    ref.read(playerControllerProvider.notifier).playTracks(
      _tracks,
      shuffle: true,
      context: _playbackContext,
    );
  }

  void _playFrom(int index) {
    ref.read(playerControllerProvider.notifier).playTracks(
      _tracks,
      startIndex: index,
      context: _playbackContext,
    );
  }

  // ---- Editing -----------------------------------------------------------

  Future<void> _toggleTrackLike(Track track) async {
    try {
      await ref.read(likedTracksControllerProvider.notifier).toggle(track);
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  /// Applies a drag-to-reorder.
  ///
  /// The local draft moves first so the row lands where it was dropped on that
  /// frame, then one document is written — see the fractional `position` scheme
  /// in `FirestorePlaylistService`. Reverted on failure, which is the only case
  /// where the list would otherwise show an order the database does not have.
  Future<void> _onReorder(int from, int to) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    final current = List<Track>.from(_tracks);

    // `ReorderableList` reports the destination index in the *pre-removal*
    // list, so dragging downwards needs the adjustment. Getting this wrong
    // puts the row one place from where it was dropped.
    final target = to > from ? to - 1 : to;

    final moved = current.removeAt(from);
    current.insert(target, moved);
    setState(() => _draftOrder = current);

    try {
      await ref.read(libraryRepositoryProvider).reorderPlaylist(
        uid: uid,
        playlistId: _playlist.id,
        ordered: widget.detail.tracks,
        from: from,
        to: target,
      );
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _draftOrder = null);
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  Future<void> _removeTrack(Track track) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    try {
      await ref.read(libraryRepositoryProvider).removeTrackFromPlaylist(
        uid: uid,
        playlistId: _playlist.id,
        trackId: track.documentId,
      );
      if (!mounted) return;
      // Undoable rather than confirmed. The old version asked "Remove from
      // playlist?" first, which is the wrong shape for an action that is one
      // write to undo — a dialog costs every user a tap to protect against a
      // mistake that costs one.
      AppSnackbar.undoable(
        context,
        'Removed from ${_playlist.name}',
        onUndo: () => _readdTrack(track),
      );
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  Future<void> _readdTrack(Track track) async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;
    try {
      await ref.read(libraryRepositoryProvider).addTrackToPlaylist(
        uid: uid,
        playlistId: _playlist.id,
        track: track,
      );
    } on Object {
      // The undo failed and its snackbar has gone. The stream is the truth, so
      // the list is still an honest view either way.
    }
  }

  Future<void> _rename() async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    final result = await PlaylistDetailsSheet.show(
      context,
      initialName: _playlist.name,
      initialDescription: _playlist.description,
    );
    if (result == null || !mounted) return;

    try {
      await ref.read(libraryRepositoryProvider).renamePlaylist(
        uid: uid,
        playlistId: _playlist.id,
        name: result.name,
        description: result.description,
      );
      if (mounted) AppSnackbar.success(context, 'Playlist updated');
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  Future<void> _delete() async {
    final uid = ref.read(currentUserIdProvider);
    if (uid == null) return;

    // Confirmed, unlike removing one track: deleting a playlist destroys the
    // arrangement as well as the membership, and there is no one-write undo.
    final confirmed = await ConfirmDialog.show(
      context,
      title: 'Delete playlist?',
      message: '"${_playlist.name}" and its ${_tracks.length} songs will be '
          'removed. The songs stay in your Liked Songs if you liked them.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    try {
      await ref
          .read(libraryRepositoryProvider)
          .deletePlaylist(uid: uid, playlistId: _playlist.id);
      if (!mounted) return;
      context.pop();
      AppSnackbar.success(context, 'Playlist deleted');
    } on Object catch (error) {
      if (!mounted) return;
      AppSnackbar.error(context, ErrorMapper.fromUnknown(error).message);
    }
  }

  // ---- Sheets ------------------------------------------------------------

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

  /// The overflow menu.
  ///
  /// Playback and sharing are offered to everybody; the rows that *change* the
  /// playlist are offered only to whoever may change it. On a catalogue
  /// playlist imported by somebody else that means renaming, reordering and
  /// deleting are absent rather than present and disabled — a disabled row
  /// invites the question "why?", and the honest answer ("it is not yours") is
  /// better expressed by the row not being there.
  ///
  /// Syncing is the exception among the write actions, and deliberately so:
  /// refreshing a shared playlist against its source is something any account
  /// may do, and it is how the catalogue stays current rather than frozen at
  /// whatever the first importer saw. See `PlaylistImportService._resyncPlaylist`
  /// for the one thing such a sync will not do.
  void _showMore() {
    final tracks = _tracks;
    final editable = _isEditable;

    BottomSheetMenu.show(
      context,
      title: _playlist.name,
      subtitle: _playlist.importCredit ?? 'By ${_playlist.ownerName}',
      imageUrl: _playlist.thumbnailUrl,
      actions: [
        SheetAction(
          icon: AurixGlyph.playlist,
          label: 'Add all to queue',
          enabled: tracks.isNotEmpty,
          onTap: () {
            ref.read(playerControllerProvider.notifier).addAllToQueue(tracks);
            AppSnackbar.success(context, 'Added ${tracks.length} songs to queue');
          },
        ),
        if (editable)
          SheetAction(
            icon: AurixGlyph.palette,
            label: 'Rename or edit description',
            onTap: _rename,
          ),
        if (editable)
          SheetAction(
            icon: AurixGlyph.dragHandle,
            label: _reordering ? 'Done reordering' : 'Reorder songs',
            enabled: tracks.length > 1,
            onTap: () => setState(() {
              _reordering = !_reordering;
              if (!_reordering) _draftOrder = null;
            }),
          ),
        // Only on a playlist that came from somewhere. An AURIX-native
        // playlist has no source to sync against, so the row is absent rather
        // than present and disabled — there is nothing to explain.
        if (_playlist.canSync)
          SheetAction(
            icon: AurixGlyph.refresh,
            label: 'Sync playlist',
            onTap: _resync,
          ),
        SheetAction(
          icon: AurixGlyph.share,
          label: 'Share',
          onTap: _share,
        ),
        if (editable)
          SheetAction(
            icon: AurixGlyph.trash,
            label: 'Delete playlist',
            destructive: true,
            onTap: _delete,
          ),
      ],
    );
  }

  /// Re-fetches the playlist from its source and reconciles it.
  ///
  /// Adds what the source has added, removes what it no longer lists, and
  /// restores the source's order — see [PlaylistImportService]. The playlist
  /// screen watches Firestore, so the rows update underneath the user without
  /// anything here refreshing them.
  Future<void> _resync() async {
    final playlist = _playlist;
    AppSnackbar.show(context, 'Syncing "${playlist.name}"…');

    try {
      final outcome = await ref.read(resyncPlaylistProvider)(playlist);
      if (!mounted) return;

      final changed = outcome.addedCount > 0 || outcome.removedCount > 0;
      AppSnackbar.success(
        context,
        changed
            ? 'Synced · ${outcome.addedCount} added, '
                  '${outcome.removedCount} removed'
            : 'Already up to date',
      );
    } on ImportFailure catch (failure) {
      if (!mounted) return;
      // The failure's own message, which is written for a person — never the
      // underlying exception.
      AppSnackbar.error(context, failure.message);
    } on Object {
      if (!mounted) return;
      AppSnackbar.error(context, 'Could not sync this playlist.');
    }
  }

  void _showTrackMenu(Track track) {
    final controller = ref.read(playerControllerProvider.notifier);
    final artist = track.primaryArtist;
    final album = track.album;

    BottomSheetMenu.show(
      context,
      title: track.name,
      subtitle: track.artistNames,
      imageUrl: track.thumbnailUrl,
      note: track.addedAt == null
          ? null
          : 'Added ${Formatters.relativeTime(track.addedAt!)}',
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
        SheetAction(
          icon: AurixGlyph.add,
          label: 'Add to playlist',
          onTap: () => AddToPlaylistSheet.show(context, track: track),
        ),
        // Only offered when there is a catalogue entry behind the row. An
        // AURIX-native track has no artist or album page to open — the ids
        // come from the source, and a track that was never imported from one
        // has none.
        if (artist != null && artist.id.isNotEmpty)
          SheetAction(
            icon: AurixGlyph.profile,
            label: 'Go to artist',
            onTap: () => context.pushDistinct(
              RouteNames.artist,
              pathParameters: {'id': artist.id},
            ),
          ),
        if (album != null && album.id.isNotEmpty)
          SheetAction(
            icon: AurixGlyph.album,
            label: 'Go to album',
            onTap: () => context.pushDistinct(
              RouteNames.album,
              pathParameters: {'id': album.id},
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
        // Absent on a catalogue playlist this account did not import: removing
        // a song there removes it for every user who opens the playlist, and
        // the rules permit that to the importer alone.
        if (_isEditable)
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

/// The playlist is not there.
///
/// Reachable two ways, and both are real: a deep link to an id that never
/// existed, and a playlist deleted on another device while this screen was
/// open. The stream reports both as null rather than as an error, because
/// neither is one.
class _Missing extends StatelessWidget {
  const _Missing();

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
          const Expanded(
            child: EmptyView(
              icon: AurixGlyph.playlist,
              title: 'Playlist not found',
              message: 'It may have been deleted.',
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
