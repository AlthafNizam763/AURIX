import 'dart:async';

import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/saved_item.dart';
import '../models/track.dart';
import '../services/firebase/firestore_library_service.dart';
import '../services/firebase/firestore_playlist_service.dart';

/// Everything the signed-in user owns.
///
/// The Spotify version of this class fetched five endpoints concurrently,
/// degraded each one independently, and wrote the results into
/// `SharedPreferences` so the app had something to show offline. All of that
/// machinery is gone, and it is worth being explicit that it was *removed*
/// rather than reimplemented:
///
///  * **No manual cache.** Firestore's own persistence serves every query from
///    disk when the network is gone and reconciles on reconnect. A second cache
///    on top of it would be a second answer to "what is in my library", and the
///    two would disagree.
///  * **No per-section error degradation.** There are no five endpoints to fail
///    independently — there is one database, and one permission model.
///  * **No paging.** The collections are the user's own and are small. Liked
///    songs is capped at a large limit rather than paged, because a query that
///    returns 500 documents from local cache is not a page the user waits for.
///
/// What replaced it is streams. Every screen watches rather than fetches, so a
/// like on the player screen reaches the Liked Songs list, the Home shelf and
/// another signed-in device without anything invalidating anything.
class LibraryRepository {
  LibraryRepository({
    required FirestoreLibraryService libraryService,
    required FirestorePlaylistService playlistService,
  }) : _library = libraryService,
       _playlists = playlistService;

  final FirestoreLibraryService _library;
  final FirestorePlaylistService _playlists;

  // ---- Liked songs -------------------------------------------------------

  Stream<List<Track>> watchLikedTracks(String uid) =>
      _library.watchLikedTracks(uid);

  Future<List<Track>> readLikedTracks(String uid) =>
      _library.readLikedTracks(uid);

  Future<void> likeTrack(String uid, Track track) => _library.like(uid, track);

  Future<void> unlikeTrack(String uid, Track track) =>
      _library.unlike(uid, track);

  /// Which of [trackIds] the user has liked.
  Future<Set<String>> likedAmong(String uid, List<String> trackIds) =>
      _library.likedAmong(uid, trackIds);

  // ---- Playlists ---------------------------------------------------------

  Stream<List<Playlist>> watchPlaylists(String uid) =>
      _playlists.watchPlaylists(uid);

  Stream<Playlist?> watchPlaylist(String uid, String playlistId) =>
      _playlists.watchPlaylist(uid, playlistId);

  Stream<List<Track>> watchPlaylistTracks(String uid, String playlistId) =>
      _playlists.watchTracks(uid, playlistId);

  Future<List<Track>> readPlaylistTracks(String uid, String playlistId) =>
      _playlists.readTracks(uid, playlistId);

  Future<String> createPlaylist({
    required String uid,
    required String name,
    String description = '',
    String coverUrl = '',
    MediaSource source = MediaSource.aurix,
    String? sourceId,
  }) => _playlists.create(
    uid: uid,
    name: name,
    description: description,
    coverUrl: coverUrl,
    source: source,
    sourceId: sourceId,
  );

  Future<void> renamePlaylist({
    required String uid,
    required String playlistId,
    required String name,
    String? description,
  }) => _playlists.rename(
    uid: uid,
    playlistId: playlistId,
    name: name,
    description: description,
  );

  Future<void> deletePlaylist({
    required String uid,
    required String playlistId,
  }) => _playlists.delete(uid: uid, playlistId: playlistId);

  Future<void> addTrackToPlaylist({
    required String uid,
    required String playlistId,
    required Track track,
  }) => _playlists.addTrack(uid: uid, playlistId: playlistId, track: track);

  /// Adds one track to several playlists at once.
  ///
  /// The "add to multiple playlists" case from the spec. Sequential rather than
  /// concurrent: each add is a transaction on a different parent document, and
  /// firing them together buys nothing measurable while making a partial
  /// failure harder to report — the caller is told which ones landed.
  Future<List<String>> addTrackToPlaylists({
    required String uid,
    required List<String> playlistIds,
    required Track track,
  }) async {
    final added = <String>[];
    for (final playlistId in playlistIds) {
      try {
        await _playlists.addTrack(
          uid: uid,
          playlistId: playlistId,
          track: track,
        );
        added.add(playlistId);
      } on Object {
        // Reported by omission from the returned list.
        continue;
      }
    }
    return added;
  }

  Future<int> addTracksToPlaylist({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) => _playlists.addTracks(uid: uid, playlistId: playlistId, tracks: tracks);

  Future<void> removeTrackFromPlaylist({
    required String uid,
    required String playlistId,
    required String trackId,
  }) => _playlists.removeTrack(
    uid: uid,
    playlistId: playlistId,
    trackId: trackId,
  );

  Future<void> reorderPlaylist({
    required String uid,
    required String playlistId,
    required List<Track> ordered,
    required int from,
    required int to,
  }) => _playlists.reorder(
    uid: uid,
    playlistId: playlistId,
    ordered: ordered,
    from: from,
    to: to,
  );

  Future<Playlist?> findImportedPlaylist({
    required String uid,
    required MediaSource source,
    required String sourceId,
  }) => _playlists.findBySource(uid, source: source, sourceId: sourceId);

  // ---- History -----------------------------------------------------------

  Stream<List<PlayHistoryEntry>> watchRecentlyPlayed(String uid) =>
      _library.watchRecentlyPlayed(uid);

  Future<void> recordPlay(String uid, Track track) =>
      _library.recordPlay(uid, track);

  Future<void> clearHistory(String uid) => _library.clearHistory(uid);
}
