import 'dart:async';

import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/firebase/firestore_global_playlist_service.dart';

/// The shared AURIX playlist catalogue.
///
/// ## The one place shared-playlist writes happen
///
/// Every write to `/playlists` in the app goes through this class, and that is
/// the point of it existing as a thin layer over
/// [FirestoreGlobalPlaylistService] rather than callers using the service
/// directly. The reasoning is [CatalogRepository]'s, one level up: the
/// collection is *shared*, so the one-line ownership rule that secures
/// everything under `/users/{uid}` does not apply to it. Its protection is
/// (a) the shape validation in the `/playlists` block of `firestore.rules`, and
/// (b) the fact that exactly one code path reaches it. Scattering
/// `db.collection('playlists')` across the import providers would dissolve (b)
/// and make (a) the only line of defence.
///
/// ## What "shared" does and does not mean
///
/// It means **discovery is not scoped to an account**. A playlist any user
/// imports is searchable, openable and playable by every signed-in AURIX user;
/// no method here takes a uid to filter a read by, and [importedBy] — which
/// does take one — answers "what have I contributed?" for the Library screen
/// rather than gating anything.
///
/// It does not mean the database is public. Liked songs, play history, the
/// profile, per-account settings and playlists the user built in AURIX all stay
/// under `/users/{uid}`, readable by that account alone. Sharing the imported
/// catalogue is not sharing the library.
///
/// ## Moving writes server-side later
///
/// The stricter arrangement is for the client to have no write access here at
/// all, and for a Cloud Function to do the fetching and the writing. That is a
/// change to [publish] and to one block of `firestore.rules` — nothing else in
/// the app knows how a playlist reaches the catalogue, because nothing else
/// calls anything but this.
///
/// What it would buy, stated honestly so the trade is visible: the client could
/// no longer write a well-formed but *untrue* playlist — a real title over
/// somebody else's cover art, or a title chosen to rank against a popular
/// query. The rules enforce shape, not truthfulness, and a catalogue every user
/// reads is a more attractive target than a catalogue of songs. What it would
/// cost: the Blaze plan, a deployed function, and an import that fails when the
/// function is cold. The current arrangement is the right default for a
/// client-only app; this comment is the map for changing it.
class PlaylistCatalogRepository {
  PlaylistCatalogRepository({
    required FirestoreGlobalPlaylistService catalogService,
  }) : _catalog = catalogService;

  final FirestoreGlobalPlaylistService _catalog;

  // ---- Discovery ---------------------------------------------------------

  /// Searches the shared catalogue. An indexed lookup, never a scan — see
  /// [FirestoreGlobalPlaylistService.search].
  Future<List<Playlist>> search(String query, {int limit = 20}) =>
      _catalog.search(query, limit: limit);

  /// One shared playlist, live. No uid: this is what lets any signed-in account
  /// open a playlist somebody else imported.
  Stream<Playlist?> watch(String playlistId) => _catalog.watch(playlistId);

  Future<Playlist?> read(String playlistId) => _catalog.read(playlistId);

  /// A shared playlist's tracks, in playlist order — one copy, read by
  /// everybody who opens it.
  Stream<List<Track>> watchTracks(String playlistId) =>
      _catalog.watchTracks(playlistId);

  Future<List<Track>> readTracks(String playlistId) =>
      _catalog.readTracks(playlistId);

  /// Has anybody imported this playlist before?
  ///
  /// Global by construction — see [FirestoreGlobalPlaylistService.findBySource]
  /// for why there is no uid to pass.
  Future<Playlist?> findBySource({
    required MediaSource source,
    required String sourceId,
  }) => _catalog.findBySource(source: source, sourceId: sourceId);

  /// What [uid] has contributed to the catalogue.
  ///
  /// The Library screen's question, not a discovery filter. Everything this
  /// returns is equally visible to every other user.
  Stream<List<Playlist>> importedBy(String uid) => _catalog.watchImportedBy(uid);

  // ---- Writes ------------------------------------------------------------

  /// Adds an imported playlist to the catalogue, or refreshes the entry already
  /// there. Returns the shared document id.
  ///
  /// Idempotent: the id is derived from (`source`, `sourceId`), so publishing
  /// the same source playlist twice — from one account or from two — writes one
  /// document. See [PlaylistKey].
  Future<String> publish({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) => _catalog.upsert(
    source: source,
    sourceId: sourceId,
    name: name,
    importedByUserId: importedByUserId,
    description: description,
    coverUrl: coverUrl,
    sourceUrl: sourceUrl,
    importedBy: importedBy,
  );

  Future<int> writeTracksInOrder({
    required String playlistId,
    required List<Track> tracks,
  }) => _catalog.writeTracksInOrder(playlistId: playlistId, tracks: tracks);

  /// Removes rows the source no longer lists. Permitted to the importer alone —
  /// the caller checks before calling, because a track removed here is removed
  /// for every user who opens the playlist.
  Future<int> removeTracks({
    required String playlistId,
    required List<String> trackIds,
  }) => _catalog.removeTracks(playlistId: playlistId, trackIds: trackIds);

  /// Stamps a playlist as re-synced and refreshes its source-side metadata.
  Future<void> markSynced({
    required String playlistId,
    String? name,
    String? coverUrl,
  }) => _catalog.markSynced(
    playlistId: playlistId,
    name: name,
    coverUrl: coverUrl,
  );

  /// Removes a playlist from the catalogue. Refused by the rules to everyone
  /// but the importer.
  Future<void> delete(String playlistId) => _catalog.delete(playlistId);
}
