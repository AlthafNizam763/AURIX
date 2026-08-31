import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/song.dart';
import 'live_query.dart';

/// The shared song catalogue — the replacement for `FirestoreCatalogService`.
///
/// ```
/// GET  /catalog/songs/search?q=
/// GET  /catalog/songs/{id}
/// POST /catalog/songs/batch
/// POST /catalog/songs
/// ```
///
/// ## Shared, and deliberately so
///
/// This collection is not owned by the account reading it. It is what makes an
/// import a *contribution* to AURIX rather than a private copy: a song imported
/// by one user is findable in global search by every user, and stored once
/// rather than once per importer.
///
/// ## Search is still an index lookup, not a scan
///
/// The `searchTokens` design survived the migration unchanged, and that is
/// worth being explicit about because it would have been easy to drop. Mongo
/// has `$regex` and a text index, either of which would have been fewer lines;
/// both would have made a keystroke cost a scan of the catalogue.
///
/// The token array keeps the cost bounded: one indexed equality match per
/// keystroke, capped by `limit`, no matter how large the catalogue grows. What
/// it still does not buy is typo tolerance — "blnding" matches nothing — and
/// that remains the point at which a real search engine would be introduced.
/// `CatalogSearchProvider` is the seam for it.
class ApiCatalogService {
  ApiCatalogService({required AurixApiClient client, required LiveQueries live})
    : _client = client,
      _live = live;

  final AurixApiClient _client;
  final LiveQueries _live;

  Future<Song?> song(String songId) async {
    try {
      final response = await _client.get(AurixEndpoints.catalogSong(songId));
      final body = response['song'];
      if (body is! Map<String, dynamic>) return null;
      return Song.fromDocument(songId, body);
    } on Object catch (error) {
      AppLogger.debug('Catalogue song $songId not readable: $error', scope: 'catalog');
      return null;
    }
  }

  /// Reads many catalogue songs by id.
  ///
  /// Used by the import path to find out which of the songs it is about to
  /// write already exist. The Firestore version chunked this at the 30-id
  /// `whereIn` limit and stitched the pages back together; `$in` has no such
  /// cap, so a whole playlist is one request.
  ///
  /// A failed lookup is not a failed import: the write path treats an unknown
  /// song as new, and the server merges rather than replaces anyway. Logged so
  /// a genuine problem is visible rather than silent.
  Future<Map<String, Song>> songsByIds(List<String> ids) async {
    if (ids.isEmpty) return const <String, Song>{};

    try {
      final response = await _client.post(
        AurixEndpoints.catalogSongsBatch,
        body: <String, dynamic>{'ids': ids.toSet().toList()},
      );

      final songs = response['songs'];
      if (songs is! Map) return const <String, Song>{};

      final found = <String, Song>{};
      songs.forEach((key, value) {
        if (key is String && value is Map<String, dynamic>) {
          found[key] = Song.fromDocument(key, value);
        }
      });
      return found;
    } on Object catch (error) {
      AppLogger.warn(
        'Catalogue lookup failed for ${ids.length} ids',
        scope: 'catalog',
        error: error,
      );
      return const <String, Song>{};
    }
  }

  /// Songs matching [query].
  ///
  /// Never throws, for the same reason the shared playlist search does not: it
  /// is one provider among several, and a catalogue that is briefly unreachable
  /// should cost the user that section of the results rather than the page.
  Future<List<Song>> search(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return const <Song>[];

    try {
      final response = await _client.get(
        AurixEndpoints.catalogSongSearch,
        query: <String, dynamic>{'q': query, 'limit': limit},
      );

      final songs = response['songs'];
      if (songs is! List) return const <Song>[];

      final out = <Song>[];
      for (final entry in songs) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          out.add(Song.fromDocument(entry['id'] as String? ?? '', entry));
        } on Object catch (error) {
          AppLogger.warn('Skipping unreadable catalogue song', scope: 'catalog', error: error);
        }
      }
      return out;
    } on Object catch (error) {
      AppLogger.warn('Catalogue search failed for "$query"', scope: 'catalog', error: error);
      return const <Song>[];
    }
  }

  /// Writes [songs] into the catalogue, creating or improving each.
  ///
  /// Returns the number of documents actually written — new plus genuinely
  /// updated — which is smaller than `songs.length` whenever an import
  /// re-encounters songs the catalogue already had in full. A re-import of an
  /// unchanged 200-track playlist therefore costs one request and zero writes.
  ///
  /// ## Where the merge logic went
  ///
  /// Server-side. The rule it implements is unchanged — a second import may
  /// *improve* a row but never erase what is already there, and it never
  /// rewrites `source`, `createdAt`, `id` or `title` — but it belongs on the
  /// server now, because the read-then-merge-then-write sequence it performs is
  /// only atomic there. Two clients importing the same song at once used to
  /// race each other through three round trips; they now race inside one
  /// handler with the rows in hand.
  Future<int> upsertAll(List<Song> songs) async {
    if (songs.isEmpty) return 0;

    final response = await _client.post(
      AurixEndpoints.catalogSongs,
      body: <String, dynamic>{
        'songs': songs.map((song) => song.toDocument()).toList(),
      },
    );

    final written = (response['written'] as num?)?.toInt() ?? 0;
    AppLogger.info(
      'Catalogue: ${response['created'] ?? 0} new, ${response['updated'] ?? 0} improved',
      scope: 'catalog',
    );

    if (written > 0) _live.invalidate(LiveKeys.catalog);
    return written;
  }
}
