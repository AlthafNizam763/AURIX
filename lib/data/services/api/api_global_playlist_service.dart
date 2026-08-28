import 'dart:async';

import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import '../../models/playlist.dart';
import '../../models/playlist_key.dart';
import '../../models/track.dart';
import 'api_library_service.dart';
import 'api_playlist_service.dart';
import 'api_session.dart';
import 'live_query.dart';

/// The shared playlist catalogue — the replacement for
/// `FirestoreGlobalPlaylistService`.
///
/// ## Why this collection is not scoped to an account
///
/// Discovery is the requirement. An imported playlist is a contribution to
/// AURIX's catalogue, not a private copy: User A imports "Love", and Users B
/// and C must be able to search it, open it and play it without being the
/// importer.
///
/// So provenance lives in *fields* — `importedByUserId`, `importedBy`,
/// `importedAt` — and **not one of them narrows who may read**. Exactly two
/// operations consult `importedByUserId`: the delete, which only the importer
/// may perform, and [watchImportedBy], which is a presentation filter on the
/// Library screen rather than an access rule.
///
/// That distinction — recorded, not enforcing — is the whole design, and it is
/// now enforced by route handlers where it used to be enforced by
/// `firestore.rules`.
///
/// ## De-duplication is still structural
///
/// Document ids come from [PlaylistKey], derived from (`source`, `sourceId`),
/// so the same source playlist imported by two accounts addresses one document.
/// There is no read-then-write window to lose: the id *is* the check, and two
/// devices importing at the same moment upsert the same row.
class ApiGlobalPlaylistService {
  ApiGlobalPlaylistService({
    required AurixApiClient client,
    required LiveQueries live,
    required AurixSession session,
  }) : _client = client,
       _live = live,
       _session = session;

  final AurixApiClient _client;
  final LiveQueries _live;
  final AurixSession _session;

  // -------------------------------------------------------------------------
  // Reads — open to every signed-in account
  // -------------------------------------------------------------------------

  /// Playlists matching [query].
  ///
  /// Never throws. Search is one input among several in `SearchService`, and a
  /// catalogue that is briefly unreachable should cost the user that section of
  /// the results page rather than the page.
  Future<List<Playlist>> search(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return const <Playlist>[];

    try {
      final response = await _client.get(
        AurixEndpoints.sharedPlaylistSearch,
        query: <String, dynamic>{'q': query, 'limit': limit},
      );
      return ApiPlaylistService.playlistsIn(
        response['playlists'],
        visibility: PlaylistVisibility.shared,
      );
    } on Object catch (error) {
      AppLogger.warn(
        'Shared playlist search failed for "$query"',
        scope: 'catalog',
        error: error,
      );
      return const <Playlist>[];
    }
  }

  Stream<Playlist?> watch(String playlistId) =>
      _live.watch(LiveKeys.sharedPlaylist(playlistId), () => read(playlistId));

  Stream<List<Track>> watchTracks(String playlistId) => _live.watch(
    LiveKeys.sharedPlaylistTracks(playlistId),
    () => readTracks(playlistId),
  );

  /// Playlists a given account imported.
  ///
  /// A *presentation* filter, not an access rule — see the class note. Any
  /// signed-in account could ask this about any uid; the app only ever asks it
  /// about the current one, because the only screen that shows it is "my
  /// library".
  Stream<List<Playlist>> watchImportedBy(String uid) => _live.watch(
    '${LiveKeys.sharedPlaylists}:by:$uid',
    () => readImportedBy(uid),
  );

  Future<Playlist?> read(String playlistId) async {
    try {
      final response = await _client.get(AurixEndpoints.sharedPlaylist(playlistId));
      final body = response['playlist'];
      if (body is! Map<String, dynamic>) return null;
      return Playlist.fromDocument(
        playlistId,
        body,
        visibility: PlaylistVisibility.shared,
      );
    } on Object catch (error) {
      AppLogger.debug('Shared playlist $playlistId not readable: $error', scope: 'catalog');
      return null;
    }
  }

  Future<List<Track>> readTracks(String playlistId) async {
    final response = await _client.get(AurixEndpoints.sharedPlaylistTracks(playlistId));
    return ApiLibraryService.tracksIn(response['tracks']);
  }

  Future<List<Playlist>> readImportedBy(String uid) async {
    final response = await _client.get(AurixEndpoints.sharedPlaylistsImportedBy(uid));
    return ApiPlaylistService.playlistsIn(
      response['playlists'],
      visibility: PlaylistVisibility.shared,
    );
  }

  /// The duplicate-import check.
  ///
  /// Matched on (`source`, `sourceId`) first and on the canonical [sourceUrl]
  /// second: a link pasted with different tracking parameters normalises to the
  /// same URL, so the second lookup catches an import the first would miss.
  Future<Playlist?> findBySource({
    required MediaSource source,
    required String sourceId,
    String? sourceUrl,
  }) async {
    _session.requireSignedIn(whenSignedOut: 'Please sign in to import playlists.');

    final response = await _client.get(
      AurixEndpoints.findSharedPlaylist,
      query: <String, dynamic>{
        'source': source.wireValue,
        'sourceId': sourceId,
        if (sourceUrl != null && sourceUrl.isNotEmpty) 'sourceUrl': sourceUrl,
      },
    );

    final body = response['playlist'];
    if (body is! Map<String, dynamic>) return null;
    return Playlist.fromDocument(
      body['id'] as String? ?? '',
      body,
      visibility: PlaylistVisibility.shared,
    );
  }

  // -------------------------------------------------------------------------
  // Writes
  // -------------------------------------------------------------------------

  /// Creates or refreshes a shared playlist, and returns its id.
  ///
  /// The metadata half of the write is restricted server-side to the account
  /// that first imported the playlist; everyone else's upsert touches
  /// `updatedAt` and nothing more. That restriction is inherited verbatim from
  /// the Firestore rules, and the reason is a race rather than a permission
  /// model: two accounts importing the same playlist at once both pass the
  /// duplicate check, and the loser must not rewrite the winner's name, cover
  /// and provenance a moment later.
  Future<String> upsert({
    required MediaSource source,
    required String sourceId,
    required String name,
    required String importedByUserId,
    String description = '',
    String coverUrl = '',
    String? sourceUrl,
    String? importedBy,
  }) async {
    _session.requireOwner(
      importedByUserId,
      whenSignedOut: 'Please sign in to import playlists.',
    );

    // Computed here rather than server-side, deliberately. The id is a pure
    // function of (source, sourceId) — see [PlaylistKey] — and computing it on
    // the client means the caller knows the id before the write lands, which
    // is what lets the import flow navigate to the playlist optimistically.
    final id = PlaylistKey.of(source: source, sourceId: sourceId);

    final response = await _client.post(
      AurixEndpoints.sharedPlaylists,
      body: <String, dynamic>{
        'id': id,
        'source': source.wireValue,
        'sourceId': sourceId,
        'name': name.trim(),
        'description': description.trim(),
        'coverUrl': coverUrl,
        'sourceUrl': ?sourceUrl,
        'importedBy': (importedBy ?? '').trim(),
      },
    );

    AppLogger.info(
      response['created'] == true
          ? 'Created shared playlist $id'
          : 'Existing shared playlist $id',
      scope: 'import',
    );

    _live.invalidate(LiveKeys.sharedPlaylists);
    return response['id'] as String? ?? id;
  }

  /// Writes [tracks] into a shared playlist in exactly the given order.
  ///
  /// The same contract as the personal service's `writeTracksInOrder`: rows are
  /// merged so a re-import improves metadata without resetting `position`, and
  /// duplicates within one source playlist are collapsed before the write.
  Future<int> writeTracksInOrder({
    required String playlistId,
    required List<Track> tracks,
  }) async {
    if (tracks.isEmpty) return 0;

    final response = await _client.put(
      AurixEndpoints.sharedPlaylistTracks(playlistId),
      body: <String, dynamic>{
        'tracks': tracks
            .map(
              (track) => <String, dynamic>{
                'trackId': track.documentId,
                'track': track.toDocument(),
              },
            )
            .toList(),
      },
    );

    _live.invalidate(LiveKeys.sharedPlaylist(playlistId));
    return (response['written'] as num?)?.toInt() ?? 0;
  }

  Future<int> removeTracks({
    required String playlistId,
    required List<String> trackIds,
  }) async {
    if (trackIds.isEmpty) return 0;

    final response = await _client.post(
      AurixEndpoints.sharedPlaylistTracksRemove(playlistId),
      body: <String, dynamic>{'trackIds': trackIds},
    );

    _live.invalidate(LiveKeys.sharedPlaylist(playlistId));
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  Future<void> markSynced({
    required String playlistId,
    String? name,
    String? coverUrl,
  }) async {
    await _client.post(
      AurixEndpoints.sharedPlaylistSynced(playlistId),
      body: <String, dynamic>{
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (coverUrl != null && coverUrl.isNotEmpty) 'coverUrl': coverUrl,
      },
    );
    _live.invalidate(LiveKeys.sharedPlaylist(playlistId));
  }

  /// Removes a playlist from the shared catalogue.
  ///
  /// The importer alone — enforced by the API, which is the only place it can
  /// be enforced. Raised as [AurixAccessDenied] rather than a generic failure
  /// because the UI treats it differently: it is not a retry and it is not a
  /// bug, it is an answer.
  Future<void> delete(String playlistId) async {
    try {
      await _client.delete(AurixEndpoints.sharedPlaylist(playlistId));
      _live.invalidate(LiveKeys.sharedPlaylists);
    } on AurixApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden) {
        throw AurixAccessDenied(error.message, operation: 'deleteSharedPlaylist');
      }
      rethrow;
    }
  }
}
