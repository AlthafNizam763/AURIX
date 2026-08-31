import 'dart:async';

import '../models/song.dart';
import '../models/track.dart';
import '../services/api/api_catalog_service.dart';

/// The AURIX song catalogue.
///
/// ## The one place catalogue writes happen
///
/// Every write to `/catalog/songs` in the app goes through [publishAll], and
/// that is the point of this class existing as a thin layer over
/// [ApiCatalogService] rather than callers using the service directly.
///
/// The catalogue is *shared*: unlike everything under `/users/{uid}`, it is not
/// owned by the account writing to it, so the one-line ownership rule that
/// secures the rest of the database does not apply. Its protection is instead
/// (a) the strict shape validation in the `/catalog/songs` block of
/// `firestore.rules`, and (b) the fact that exactly one code path reaches it.
/// Scattering `db.collection('catalog')` across the import providers would
/// dissolve (b) and make (a) the only line of defence.
///
/// ## Moving writes server-side later
///
/// The stricter arrangement is for the client to have no catalogue write access
/// at all, and for a Cloud Function to do the fetching and the writing. That is
/// a change to [publishAll] and to one block of `firestore.rules` — nothing
/// else in the app knows how a song reaches the catalogue, because nothing else
/// calls anything but this.
///
/// What that would buy, stated honestly so the trade is visible: the client
/// could no longer write a well-formed but *untrue* song document — a real
/// title with someone else's artwork URL, say. The rules can enforce shape but
/// not truthfulness. What it would cost: the Blaze plan, a deployed function,
/// and an import that fails when the function is cold or down. The current
/// arrangement is the right default for a client-only app; this comment is the
/// map for changing it.
class CatalogRepository {
  CatalogRepository({required ApiCatalogService catalogService})
      : _catalog = catalogService;

  final ApiCatalogService _catalog;

  /// Adds songs to the catalogue, or improves the entries already there.
  ///
  /// Returns how many documents were actually written. Idempotent: publishing
  /// the same songs twice writes them once, because the document id is derived
  /// from the song rather than allocated — see [SongKey].
  Future<int> publishAll(List<Song> songs) => _catalog.upsertAll(songs);

  /// Adds the tracks of an import to the catalogue.
  ///
  /// The conversion is here rather than in the import service because
  /// [Song.fromTrack] is what decides a song's catalogue identity, and that
  /// decision belongs next to the collection it keys.
  Future<int> publishTracks(List<Track> tracks) =>
      publishAll(tracks.map(Song.fromTrack).toList(growable: false));

  /// Searches the catalogue. An indexed lookup, never a scan — see
  /// [ApiCatalogService.search].
  Future<List<Song>> search(String query, {int limit = 20}) =>
      _catalog.search(query, limit: limit);

  /// Searches the catalogue and returns runtime tracks, ready to play or queue.
  Future<List<Track>> searchTracks(String query, {int limit = 20}) async {
    final songs = await search(query, limit: limit);
    return songs.map((song) => song.toTrack()).toList(growable: false);
  }

  Future<Song?> song(String songId) => _catalog.song(songId);
}
