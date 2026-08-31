import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import 'api_global_playlist_service.dart';
import 'api_library_service.dart';
import 'api_session.dart';
import 'live_query.dart';

/// The user's own playlists — the replacement for `FirestorePlaylistService`.
///
/// ```
/// GET/POST/PATCH/DELETE  /playlists[/{id}]
/// GET/PUT/POST/DELETE    /playlists/{id}/tracks[...]
/// POST                   /playlists/{id}/reorder
/// ```
///
/// ## Where the ordering logic went
///
/// Fractional positions are unchanged as a design — a drag is one write, not N
/// — but the *arithmetic* moved to the server. It ran here before because only
/// the client knew the order the user was looking at; the client still supplies
/// that order, and the two neighbour lookups the algorithm needs are now local
/// queries on the server rather than two more network round trips.
///
/// [positionBetween] survives on this class as a pure function. It is what the
/// existing position tests exercise, and it is the reference the server
/// implementation is kept in step with.
class ApiPlaylistService {
  ApiPlaylistService({
    required AurixApiClient client,
    required LiveQueries live,
    required AurixSession session,
    required ApiGlobalPlaylistService catalog,
  }) : _client = client,
       _live = live,
       _session = session,
       _catalog = catalog;

  final AurixApiClient _client;
  final LiveQueries _live;

  /// Who the app believes is signed in.
  ///
  /// Consulted before the lookups whose failure would otherwise be a 401 from
  /// three layers down. It is no longer a security boundary — the API resolves
  /// the account from the token and cannot be talked into another one — but the
  /// message it produces is still better than the one a round trip returns.
  final AurixSession _session;

  /// The shared catalogue.
  ///
  /// Held so [findBySource] — the duplicate-import check, and the one question
  /// about a playlist that is *not* scoped to one account — can be answered
  /// without a second implementation of the shared collection living here.
  /// Everything else on this class is the user's own data.
  final ApiGlobalPlaylistService _catalog;

  /// The gap left between adjacent tracks. Mirrors the server constant.
  static const double positionGap = 1024;

  /// Below this, two positions are too close to reliably find a midpoint.
  static const double minimumGap = 0.0001;

  // -------------------------------------------------------------------------
  // Reads
  // -------------------------------------------------------------------------

  /// Every playlist the user owns, newest edit first.
  ///
  /// Ordered by `updatedAt` rather than by name: a library screen is a list of
  /// things you are working with, and the one you touched last is the one you
  /// are most likely to want. The screen re-sorts locally when the user asks
  /// for something else, which costs nothing on a list this size.
  Stream<List<Playlist>> watchPlaylists(String uid) =>
      _live.watch(LiveKeys.playlists(uid), () => readPlaylists(uid));

  Stream<Playlist?> watchPlaylist(String uid, String playlistId) => _live.watch(
    LiveKeys.playlist(uid, playlistId),
    () => readPlaylist(uid, playlistId),
  );

  Stream<List<Track>> watchTracks(String uid, String playlistId) => _live.watch(
    LiveKeys.playlistTracks(uid, playlistId),
    () => readTracks(uid, playlistId),
  );

  Future<List<Playlist>> readPlaylists(String uid) async {
    final response = await _client.get(AurixEndpoints.playlists);
    return _playlistsIn(response['playlists']);
  }

  Future<Playlist?> readPlaylist(String uid, String playlistId) async {
    try {
      final response = await _client.get(AurixEndpoints.playlist(playlistId));
      final body = response['playlist'];
      if (body is! Map<String, dynamic>) return null;
      return Playlist.fromDocument(playlistId, body);
    } on Object catch (error) {
      AppLogger.debug('Playlist $playlistId not readable: $error', scope: 'playlists');
      return null;
    }
  }

  Future<List<Track>> readTracks(String uid, String playlistId) async {
    final response = await _client.get(AurixEndpoints.playlistTracks(playlistId));
    return ApiLibraryService.tracksIn(response['tracks']);
  }

  /// Finds an already-imported playlist by its identity at the source.
  ///
  /// What makes re-importing update rather than duplicate. Returns null when
  /// **nobody** has imported this playlist before.
  ///
  /// ## Why there is no uid here
  ///
  /// This once queried the importing account's own collection, which meant the
  /// answer to "has this been imported?" was different for every user, and User
  /// B re-importing a playlist User A had already brought in created a second
  /// copy. Under the shared catalogue there is one answer: the pair (`source`,
  /// `sourceId`) identifies a playlist across the whole product.
  ///
  /// So the lookup deliberately carries **no uid filter**. Adding one back
  /// would restore exactly the behaviour the shared catalogue exists to remove.
  Future<Playlist?> findBySource({
    required MediaSource source,
    required String sourceId,
  }) async {
    _session.requireSignedIn(whenSignedOut: 'Please sign in to import playlists.');
    return _catalog.findBySource(source: source, sourceId: sourceId);
  }

  /// The same question, asked of this user's **own** playlists.
  ///
  /// Kept for one caller: [LocalDataMigration], which rebuilds placeholder
  /// playlists from a pre-migration install's local cache. Those are names and
  /// source ids with no tracks, no cover and no verified metadata — they belong
  /// in the user's own library, not published into a catalogue every other user
  /// reads. This is what lets that path de-duplicate against itself without
  /// touching the shared collection.
  Future<Playlist?> findOwnBySource(
    String uid, {
    required MediaSource source,
    required String sourceId,
  }) async {
    _session.requireOwner(uid, whenSignedOut: 'Please sign in to import playlists.');

    final response = await _client.get(
      AurixEndpoints.findPlaylist,
      query: <String, dynamic>{'source': source.wireValue, 'sourceId': sourceId},
    );

    final body = response['playlist'];
    if (body is! Map<String, dynamic>) return null;
    return Playlist.fromDocument(body['id'] as String? ?? '', body);
  }

  // -------------------------------------------------------------------------
  // Playlist lifecycle
  // -------------------------------------------------------------------------

  Future<String> create({
    required String uid,
    required String name,
    String description = '',
    String coverUrl = '',
    MediaSource source = MediaSource.aurix,
    String? sourceId,
    String? sourceUrl,
  }) async {
    final response = await _client.post(
      AurixEndpoints.playlists,
      body: <String, dynamic>{
        'name': name.trim(),
        'description': description.trim(),
        'coverUrl': coverUrl,
        'source': source.wireValue,
        'sourceId': ?sourceId,
        'sourceUrl': ?sourceUrl,
      },
    );

    final id = response['id'] as String? ?? '';
    AppLogger.info('Created playlist $id', scope: 'playlists');
    _live.invalidate(LiveKeys.playlists(uid));
    return id;
  }

  Future<void> rename({
    required String uid,
    required String playlistId,
    required String name,
    String? description,
  }) async {
    await _client.patch(
      AurixEndpoints.playlist(playlistId),
      body: <String, dynamic>{
        'name': name.trim(),
        if (description != null) 'description': description.trim(),
      },
    );
    _live.invalidate(LiveKeys.playlists(uid));
  }

  /// Records the outcome of a re-sync against the playlist's source.
  ///
  /// Separate from [rename] because a sync updates provenance rather than the
  /// user's own edits: it refreshes the cover and the source-side name and
  /// stamps `syncedAt`.
  ///
  /// The description is deliberately **not** touched. The user may have edited
  /// it here, and overwriting an edit with a stale line from the source is
  /// worse than leaving the line stale.
  Future<void> markSynced({
    required String uid,
    required String playlistId,
    String? name,
    String? coverUrl,
  }) async {
    await _client.post(
      AurixEndpoints.playlistSynced(playlistId),
      body: <String, dynamic>{
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
      },
    );
    _live.invalidate(LiveKeys.playlist(uid, playlistId));
    _live.invalidate(LiveKeys.playlists(uid));
  }

  Future<void> setCover({
    required String uid,
    required String playlistId,
    required String coverUrl,
  }) async {
    await _client.put(
      AurixEndpoints.playlistCover(playlistId),
      body: <String, dynamic>{'coverUrl': coverUrl},
    );
    _live.invalidate(LiveKeys.playlist(uid, playlistId));
    _live.invalidate(LiveKeys.playlists(uid));
  }

  /// Deletes a playlist and everything in it.
  ///
  /// The track rows go first, server-side, in the same handler. Firestore
  /// required that because it does not cascade into subcollections; MongoDB
  /// requires it because the rows are a separate collection keyed on the
  /// playlist id. Either way, skipping it leaves invisible orphans that would
  /// reappear in full if an id were ever reused.
  Future<void> delete({required String uid, required String playlistId}) async {
    await _client.delete(AurixEndpoints.playlist(playlistId));
    _live.invalidate(LiveKeys.playlists(uid));
  }

  // -------------------------------------------------------------------------
  // Track membership
  // -------------------------------------------------------------------------

  Future<void> addTrack({
    required String uid,
    required String playlistId,
    required Track track,
  }) async {
    await _client.post(
      AurixEndpoints.playlistTracks(playlistId),
      body: _entry(track),
    );
    _touched(uid, playlistId);
  }

  Future<int> addTracks({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return 0;

    final response = await _client.post(
      AurixEndpoints.playlistTracksBulk(playlistId),
      body: <String, dynamic>{'tracks': tracks.map(_entry).toList()},
    );

    _touched(uid, playlistId);
    return (response['added'] as num?)?.toInt() ?? 0;
  }

  /// Writes [tracks] into a playlist in exactly the given order.
  ///
  /// Distinct from [addTracks], which appends after whatever is already there.
  /// This assigns positions from the start of the list, so the playlist ends up
  /// in the source's order — which is what a re-sync wants when the source has
  /// reordered, and what a first import wants because there is nothing to
  /// append to.
  ///
  /// Rows are merged, so a track that was already present keeps its `createdAt`
  /// and gains whatever metadata improved.
  Future<int> writeTracksInOrder({
    required String uid,
    required String playlistId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return 0;

    final response = await _client.put(
      AurixEndpoints.playlistTracks(playlistId),
      body: <String, dynamic>{'tracks': tracks.map(_entry).toList()},
    );

    _touched(uid, playlistId);
    return (response['written'] as num?)?.toInt() ?? 0;
  }

  Future<void> removeTrack({
    required String uid,
    required String playlistId,
    required String trackId,
  }) async {
    await _client.delete(AurixEndpoints.playlistTrack(playlistId, trackId));
    _touched(uid, playlistId);
  }

  /// Removes the rows in [trackIds] from a playlist.
  ///
  /// The deletion half of a re-sync: songs the source no longer lists.
  Future<int> removeTracks({
    required String uid,
    required String playlistId,
    required List<String> trackIds,
  }) async {
    if (trackIds.isEmpty) return 0;

    final response = await _client.post(
      AurixEndpoints.playlistTracksRemove(playlistId),
      body: <String, dynamic>{'trackIds': trackIds},
    );

    _touched(uid, playlistId);
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  /// Moves the track at [from] to [to] in the current ordering.
  ///
  /// [ordered] must be the list as the user currently sees it — the caller has
  /// it already, and passing it avoids a re-read of the whole playlist to
  /// discover an order the screen is holding.
  ///
  /// One document is written in the normal case; see the class note.
  Future<void> reorder({
    required String uid,
    required String playlistId,
    required List<Track> ordered,
    required int from,
    required int to,
  }) async {
    if (from == to) return;
    if (from < 0 || from >= ordered.length) return;

    await _client.post(
      AurixEndpoints.playlistReorder(playlistId),
      body: <String, dynamic>{
        'orderedTrackIds': ordered.map((track) => track.documentId).toList(),
        'from': from,
        'to': to,
      },
    );

    _touched(uid, playlistId);
  }

  // -------------------------------------------------------------------------
  // Positioning
  // -------------------------------------------------------------------------

  /// The position to give a track landing between two neighbours, or null when
  /// there is no room left between them.
  ///
  /// The authoritative copy runs on the server — it is the one with the
  /// neighbour positions in hand. This is kept because it is a pure function
  /// worth testing on this side of the wire, and because it documents the
  /// contract the server implements: a null means "renumber the list", not
  /// "give both tracks the same position".
  @visibleForTesting
  static double? positionBetween(double? before, double? after) {
    if (before == null && after == null) return positionGap;
    if (before == null) return after! - positionGap;
    if (after == null) return before + positionGap;
    if ((after - before).abs() < minimumGap) return null;
    return before + (after - before) / 2;
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  static Map<String, dynamic> _entry(Track track) => <String, dynamic>{
    'trackId': track.documentId,
    'track': track.toDocument(),
  };

  /// A membership change moves both the track list and the playlist's own
  /// `trackCount` and `updatedAt`, so both keys wake.
  void _touched(String uid, String playlistId) {
    _live.invalidate(LiveKeys.playlist(uid, playlistId));
    _live.invalidate(LiveKeys.playlists(uid));
  }

  static List<Playlist> _playlistsIn(Object? raw) {
    if (raw is! List) return const <Playlist>[];

    final out = <Playlist>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        out.add(Playlist.fromDocument(entry['id'] as String? ?? '', entry));
      } on Object catch (error) {
        AppLogger.warn('Skipping unreadable playlist', scope: 'playlists', error: error);
      }
    }
    return out;
  }

  /// Shared with the shared-catalogue service, which parses the same shape.
  static List<Playlist> playlistsIn(
    Object? raw, {
    PlaylistVisibility visibility = PlaylistVisibility.private,
  }) {
    if (raw is! List) return const <Playlist>[];

    final out = <Playlist>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      try {
        out.add(
          Playlist.fromDocument(
            entry['id'] as String? ?? '',
            entry,
            visibility: visibility,
          ),
        );
      } on Object catch (error) {
        AppLogger.warn('Skipping unreadable playlist', scope: 'playlists', error: error);
      }
    }
    return out;
  }
}
