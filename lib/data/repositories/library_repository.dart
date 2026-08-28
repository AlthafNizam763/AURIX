import 'dart:async';

import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/playlist_key.dart';
import '../models/saved_item.dart';
import '../models/track.dart';
import '../services/api/api_library_service.dart';
import '../services/api/api_playlist_service.dart';
import 'playlist_catalog_repository.dart';

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
    required ApiLibraryService libraryService,
    required ApiPlaylistService playlistService,
    required PlaylistCatalogRepository playlistCatalog,
  }) : _library = libraryService,
       _playlists = playlistService,
       _catalog = playlistCatalog;

  final ApiLibraryService _library;
  final ApiPlaylistService _playlists;

  /// The shared playlist catalogue.
  ///
  /// Held because "the user's library" is no longer one collection: a playlist
  /// they built here is private and a playlist they imported is shared, and the
  /// Library screen has to show both. See [watchPlaylists], which is where the
  /// two are joined, and [PlaylistCatalogRepository] for why the shared half is
  /// not simply nested under the user.
  final PlaylistCatalogRepository _catalog;

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

  /// Everything on the user's Library shelf: playlists they built here, plus
  /// the ones they imported.
  ///
  /// Two collections, joined here rather than in a screen. A personal playlist
  /// lives at `/users/{uid}/playlists`; an imported one lives in the shared
  /// catalogue at `/playlists` with `importedByUserId == uid`. The user does not
  /// experience that split and should not have to — both are "my playlists" on
  /// the shelf, and only the overflow menu ever distinguishes them.
  ///
  /// Emits as soon as *either* side arrives rather than waiting for both, so
  /// the shelf fills in instead of blocking on the slower stream. Both are
  /// Firestore streams served from the local cache when offline, so in practice
  /// they land together.
  Stream<List<Playlist>> watchPlaylists(String uid) {
    final personal = _playlists.watchPlaylists(uid);
    final imported = _catalog.importedBy(uid);
    return _combinePlaylists(personal, imported);
  }

  /// Just the playlists the user built here. Used by "Add to playlist", which
  /// must not offer a shared playlist as a destination — adding a track to one
  /// would add it for every user who opens it, and only the importer may.
  Stream<List<Playlist>> watchOwnPlaylists(String uid) =>
      _playlists.watchPlaylists(uid);

  /// One playlist, from whichever collection its id names.
  ///
  /// [PlaylistKey.isGlobal] decides, and it decides without a probe read: a
  /// shared playlist's id is derived and always begins `pl_`, while a personal
  /// one carries a Firestore auto-id, which is drawn from an alphabet with no
  /// underscore in it. So the test is exact rather than a heuristic, and a deep
  /// link to `/playlist/:id` opens the right document first time.
  ///
  /// The global branch takes no uid at all. That is what makes User B able to
  /// open a playlist User A imported.
  Stream<Playlist?> watchPlaylist(String uid, String playlistId) =>
      PlaylistKey.isGlobal(playlistId)
          ? _catalog.watch(playlistId)
          : _playlists.watchPlaylist(uid, playlistId);

  Stream<List<Track>> watchPlaylistTracks(String uid, String playlistId) =>
      PlaylistKey.isGlobal(playlistId)
          ? _catalog.watchTracks(playlistId)
          : _playlists.watchTracks(uid, playlistId);

  Future<List<Track>> readPlaylistTracks(String uid, String playlistId) =>
      PlaylistKey.isGlobal(playlistId)
          ? _catalog.readTracks(playlistId)
          : _playlists.readTracks(uid, playlistId);

  /// Searches the shared catalogue by title. See
  /// [PlaylistCatalogRepository.search].
  Future<List<Playlist>> searchSharedPlaylists(
    String query, {
    int limit = 20,
  }) => _catalog.search(query, limit: limit);

  /// Joins the two playlist streams into one shelf.
  ///
  /// Written by hand rather than pulled from `rxdart`: it is one combine, the
  /// app has no other use for the package, and the emit-on-either-side
  /// behaviour below is the specific thing wanted rather than the default.
  ///
  /// De-duplicated on (`source`, `sourceId`) with the shared copy winning.
  /// That matters for one real case: a user who imported a playlist under the
  /// previous architecture has a personal copy of it, and importing it again
  /// now publishes it to the catalogue. Without this they would see the
  /// playlist twice on their own shelf. Personal playlists the user *made*
  /// have no `sourceId` and are never collapsed.
  static Stream<List<Playlist>> _combinePlaylists(
    Stream<List<Playlist>> personal,
    Stream<List<Playlist>> imported,
  ) {
    List<Playlist>? latestPersonal;
    List<Playlist>? latestImported;

    late StreamController<List<Playlist>> controller;
    StreamSubscription<List<Playlist>>? personalSubscription;
    StreamSubscription<List<Playlist>>? importedSubscription;
    var personalDone = false;
    var importedDone = false;

    /// Closes only once *both* sides are finished.
    ///
    /// Firestore snapshot streams do not end in production, so this is the
    /// path a test with finite streams takes — and without it such a test
    /// hangs waiting for a stream that will never close.
    void closeIfDone() {
      if (personalDone && importedDone && !controller.isClosed) {
        controller.close();
      }
    }

    void emit() {
      // Neither side has answered yet — nothing to say. Once one has, its
      // result is emitted with the other treated as empty, so the shelf shows
      // what it has instead of waiting.
      if (latestPersonal == null && latestImported == null) return;

      final merged = <Playlist>[
        ...?latestImported,
        ...?latestPersonal,
      ];

      final seenSources = <String>{};
      final out = <Playlist>[];
      for (final playlist in merged) {
        final sourceId = playlist.sourceId;
        if (sourceId != null && sourceId.isNotEmpty) {
          // Shared copies come first in `merged`, so the shared one claims the
          // key and a stale personal duplicate is dropped.
          if (!seenSources.add('${playlist.source.wireValue}:$sourceId')) {
            continue;
          }
        }
        out.add(playlist);
      }

      out.sort((a, b) {
        final left = b.updatedAt;
        final right = a.updatedAt;
        if (left == null && right == null) return a.name.compareTo(b.name);
        if (left == null) return 1;
        if (right == null) return -1;
        return left.compareTo(right);
      });

      controller.add(out);
    }

    controller = StreamController<List<Playlist>>(
      onListen: () {
        personalSubscription = personal.listen(
          (value) {
            latestPersonal = value;
            emit();
          },
          // A failure on one side must not empty the shelf: the other side is
          // still a true answer, and an empty library reads as data loss.
          onError: (Object error, StackTrace stackTrace) {
            latestPersonal ??= const <Playlist>[];
            if (latestImported == null) {
              controller.addError(error, stackTrace);
            } else {
              emit();
            }
          },
          onDone: () {
            personalDone = true;
            closeIfDone();
          },
        );
        importedSubscription = imported.listen(
          (value) {
            latestImported = value;
            emit();
          },
          onError: (Object error, StackTrace stackTrace) {
            latestImported ??= const <Playlist>[];
            if (latestPersonal == null) {
              controller.addError(error, stackTrace);
            } else {
              emit();
            }
          },
          onDone: () {
            importedDone = true;
            closeIfDone();
          },
        );
      },
      onCancel: () async {
        await personalSubscription?.cancel();
        await importedSubscription?.cancel();
      },
    );

    return controller.stream;
  }

  Future<String> createPlaylist({
    required String uid,
    required String name,
    String description = '',
    String coverUrl = '',
    MediaSource source = MediaSource.aurix,
    String? sourceId,
    String? sourceUrl,
  }) => _playlists.create(
    uid: uid,
    name: name,
    description: description,
    coverUrl: coverUrl,
    source: source,
    sourceId: sourceId,
    sourceUrl: sourceUrl,
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

  /// Deletes a playlist.
  ///
  /// A shared one goes from the catalogue for everybody, which is why the rules
  /// permit it to the importer alone and why the UI offers it to nobody else —
  /// see `Playlist.isEditableBy`.
  Future<void> deletePlaylist({
    required String uid,
    required String playlistId,
  }) => PlaylistKey.isGlobal(playlistId)
      ? _catalog.delete(playlistId)
      : _playlists.delete(uid: uid, playlistId: playlistId);

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

  /// Has **anybody** imported this playlist before?
  ///
  /// No uid: the shared catalogue has one answer for the whole product, which
  /// is what makes User B's import of a playlist User A already brought in an
  /// update rather than a second copy. See
  /// [ApiGlobalPlaylistService.findBySource].
  Future<Playlist?> findImportedPlaylist({
    required MediaSource source,
    required String sourceId,
  }) => _catalog.findBySource(source: source, sourceId: sourceId);

  /// The same question, asked of this user's own playlists only.
  ///
  /// One caller: [LocalDataMigration], which rebuilds placeholder playlists
  /// from a pre-Firebase install's local cache and must not publish them.
  Future<Playlist?> findOwnImportedPlaylist({
    required String uid,
    required MediaSource source,
    required String sourceId,
  }) => _playlists.findOwnBySource(uid, source: source, sourceId: sourceId);

  // ---- Import and re-sync ------------------------------------------------
  //
  // Three methods the link-import path needs and the hand-editing path does
  // not. They are distinguished from their neighbours by writing an *order*
  // rather than appending to one: an import's job is to make the playlist
  // match the source, where an edit's job is to change one row.
  //
  // All three route on the playlist's id: an imported playlist is in the shared
  // catalogue, and a personal one is not. See [watchPlaylist] for why the id
  // alone can decide that.

  /// Writes tracks into a playlist in exactly the given order, merging rows
  /// that are already there. See
  /// [ApiPlaylistService.writeTracksInOrder].
  Future<int> writePlaylistTracksInOrder({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) => PlaylistKey.isGlobal(playlistId)
      ? _catalog.writeTracksInOrder(playlistId: playlistId, tracks: tracks)
      : _playlists.writeTracksInOrder(
          uid: uid,
          playlistId: playlistId,
          tracks: tracks,
        );

  /// Removes several rows at once — the deletion half of a re-sync.
  Future<int> removePlaylistTracks({
    required String uid,
    required String playlistId,
    required List<String> trackIds,
  }) => PlaylistKey.isGlobal(playlistId)
      ? _catalog.removeTracks(playlistId: playlistId, trackIds: trackIds)
      : _playlists.removeTracks(
          uid: uid,
          playlistId: playlistId,
          trackIds: trackIds,
        );

  /// Stamps a playlist as re-synced and refreshes its source-side metadata.
  Future<void> markPlaylistSynced({
    required String uid,
    required String playlistId,
    String? name,
    String? coverUrl,
  }) => PlaylistKey.isGlobal(playlistId)
      ? _catalog.markSynced(
          playlistId: playlistId,
          name: name,
          coverUrl: coverUrl,
        )
      : _playlists.markSynced(
          uid: uid,
          playlistId: playlistId,
          name: name,
          coverUrl: coverUrl,
        );

  /// Publishes an imported playlist to the shared catalogue, or refreshes the
  /// entry already there. Returns the shared document id.
  ///
  /// Distinct from [createPlaylist], which makes a playlist the user owns. This
  /// contributes one to a catalogue every signed-in account can search — see
  /// [PlaylistCatalogRepository].
  Future<String> publishImportedPlaylist({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) => _catalog.publish(
    source: source,
    sourceId: sourceId,
    name: name,
    importedByUserId: importedByUserId,
    description: description,
    coverUrl: coverUrl,
    sourceUrl: sourceUrl,
    importedBy: importedBy,
  );

  // ---- History -----------------------------------------------------------

  Stream<List<PlayHistoryEntry>> watchRecentlyPlayed(String uid) =>
      _library.watchRecentlyPlayed(uid);

  Future<void> recordPlay(String uid, Track track) =>
      _library.recordPlay(uid, track);

  Future<void> clearHistory(String uid) => _library.clearHistory(uid);
}
