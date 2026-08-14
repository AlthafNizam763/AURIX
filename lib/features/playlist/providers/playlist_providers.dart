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
  const AurixPlaylistDetail({required this.playlist, required this.tracks});

  final Playlist playlist;
  final List<Track> tracks;

  /// Playlists live under `/users/{uid}` and the security rules enforce that,
  /// so anything the app can read here is the signed-in user's to change.
  ///
  /// There was a real question to answer before: a Spotify playlist could be
  /// someone else's, or collaborative, and the app had to ask Spotify which.
  bool get isEditable => true;

  Duration get totalDuration => tracks.fold<Duration>(
    Duration.zero,
    (sum, track) => sum + track.duration,
  );
}

/// The playlist behind the detail screen, live.
///
/// A [StreamProvider], so a rename, a reorder or a track added from another
/// screen — or another device — appears here without a refresh. The Spotify
/// implementation was a `FutureProvider` with a two-minute keep-alive and a
/// paging controller in the widget, because the contents came 100 at a time
/// behind `/playlists/{id}/items`.
final aurixPlaylistProvider = StreamProvider.autoDispose
    .family<AurixPlaylistDetail?, String>((ref, playlistId) {
  final uid = ref.watch(currentUserIdProvider);
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
    return AurixPlaylistDetail(playlist: playlist, tracks: tracks);
  });
});

/// The playlists a track could be added to.
///
/// Used by the "Add to playlist" sheet, which is why it is here rather than
/// derived at the call site: the sheet is reachable from four screens.
final addToPlaylistTargetsProvider =
    StreamProvider.autoDispose<List<Playlist>>((ref) {
  final uid = ref.watch(currentUserIdProvider);
  if (uid == null) return Stream<List<Playlist>>.value(const []);
  return ref.watch(libraryRepositoryProvider).watchPlaylists(uid);
});
