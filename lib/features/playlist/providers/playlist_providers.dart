import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/providers/app_providers.dart';
import '../../../data/models/playlist.dart';
import '../../../data/models/track.dart';
import '../../auth/providers/auth_provider.dart';

/// A playlist and its tracks, as the detail screen needs them.
///
/// Two Firestore documents' worth of data — the playlist document and its
/// `tracks` subcollection — combined here rather than in the service, because
/// they arrive on separate streams and the screen wants one object.
class AurixPlaylistDetail {
  const AurixPlaylistDetail({
    required this.playlist,
    required this.tracks,
    this.viewerId,
  });

  final Playlist playlist;
  final List<Track> tracks;

  /// The signed-in account looking at it, or null when nobody is.
  final String? viewerId;

  /// True when this account may rename, reorder, delete or edit membership.
  ///
  /// It used to be an unconditional `true`, and that was correct while every
  /// readable playlist lived under `/users/{uid}`: the path was the ownership
  /// claim, so anything the app could read was the user's to change.
  ///
  /// The shared catalogue breaks that equivalence, and this is where the app
  /// stops assuming it. A playlist at `/playlists/{id}` is readable and
  /// playable by every signed-in account and editable only by the one that
  /// imported it — so a viewer who is not the importer gets the whole playlist,
  /// can play it, queue it and like its songs, and is simply not offered the
  /// controls that would change it for everybody.
  bool get isEditable => playlist.isEditableBy(viewerId);

  /// True when this is a catalogue playlist somebody else contributed.
  ///
  /// Drives the "Added by …" line: worth showing precisely when the viewer did
  /// not add it themselves.
  bool get isFromAnotherUser =>
      playlist.visibility.isShared && !playlist.isImportedBy(viewerId);

  Duration get totalDuration => tracks.fold<Duration>(
    Duration.zero,
    (sum, track) => sum + track.duration,
  );
}

/// The playlist behind the detail screen, live.
///
/// A [StreamProvider], so a rename, a reorder or a track added from another
/// screen — or another device, or another *user* on a shared playlist —
/// appears here without a refresh. The Spotify implementation was a
/// `FutureProvider` with a two-minute keep-alive and a paging controller in the
/// widget, because the contents came 100 at a time behind
/// `/playlists/{id}/items`.
///
/// Works for both kinds of playlist. The repository routes on the id: one that
/// begins `pl_` is a shared catalogue playlist and is read without reference to
/// any account, which is what makes opening somebody else's import work. See
/// [LibraryRepository.watchPlaylist].
final aurixPlaylistProvider = StreamProvider.autoDispose
    .family<AurixPlaylistDetail?, String>((ref, playlistId) {
  final uid = ref.watch(currentUserIdProvider);
  // Still required, and only for authentication: the catalogue is readable by
  // signed-in accounts, not by the public. What is *not* required is that this
  // account be the one that imported the playlist.
  if (uid == null) return Stream<AurixPlaylistDetail?>.value(null);

  final repository = ref.watch(libraryRepositoryProvider);

  // The tracks stream drives the combination and the playlist document is
  // sampled into it, rather than the other way round: the tracks are what the
  // screen is mostly made of, and a rename should not make the list flicker.
  Playlist? latestPlaylist;
  final playlistSubscription = repository
      .watchPlaylist(uid, playlistId)
      .listen((playlist) => latestPlaylist = playlist);
  ref.onDispose(playlistSubscription.cancel);

  return repository.watchPlaylistTracks(uid, playlistId).map((tracks) {
    final playlist = latestPlaylist;
    if (playlist == null) return null;
    return AurixPlaylistDetail(
      playlist: playlist,
      tracks: tracks,
      viewerId: uid,
    );
  });
});

/// The playlists a track could be added to.
///
/// Used by the "Add to playlist" sheet, which is why it is here rather than
/// derived at the call site: the sheet is reachable from four screens.
///
/// Deliberately the user's **own** playlists rather than everything on their
/// shelf. A shared catalogue playlist is not a destination for "Add to
/// playlist": adding a song would add it for every user who opens it, and the
/// rules permit that to the importer alone. Offering a row that would be
/// refused is worse than not offering it.
final addToPlaylistTargetsProvider =
    StreamProvider.autoDispose<List<Playlist>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream<List<Playlist>>.value(const []);
  return ref.watch(libraryRepositoryProvider).watchOwnPlaylists(uid);
});
