import 'dart:async';

import '../models/paging.dart';
import '../models/search_results.dart';
import '../models/track.dart';
import '../repositories/catalog_repository.dart';
import 'search_provider.dart';

/// Searches the AURIX catalogue.
///
/// ## Why this is the provider that makes import work
///
/// Without it, an imported song is reachable only by opening the playlist it
/// arrived in: [LibrarySearchProvider] searches what is already in memory, and
/// the tracks of a playlist the user has not opened are not. Importing
/// "My Workout" and then searching "Blinding Lights" would find nothing, which
/// is precisely the behaviour the catalogue exists to fix.
///
/// This provider closes that gap. Every song any import has written is in
/// `/catalog/songs`, and this queries it — so a song is findable from anywhere
/// in the app the moment its playlist finishes importing, whether or not that
/// playlist has ever been opened.
///
/// ## It searches AURIX, not Spotify
///
/// Worth stating because the class it sits beside does the opposite.
/// `SpotifySearchProvider` asks Spotify's `/search` and is available only while
/// a Spotify session is live. This asks Firestore, needs no third-party
/// credentials, and — because Firestore serves queries from its local cache —
/// keeps answering when the network is gone.
///
/// ## Priority
///
/// 50: below the library (0), above any external catalogue (100+). The
/// ordering is a claim about usefulness. The user's own copy of a song wins,
/// because it is the one they can already play and rearrange. The catalogue
/// beats a remote result, because a catalogue hit is a song AURIX has real
/// metadata for and a remote one is a song it would have to fetch.
class CatalogSearchProvider implements SearchProvider {
  CatalogSearchProvider({required CatalogRepository catalog})
      : _catalog = catalog;

  final CatalogRepository _catalog;

  @override
  String get displayName => 'AURIX catalogue';

  @override
  int get priority => 50;

  /// Always. It needs no session and no network — Firestore answers from its
  /// local cache when offline, which is the same property that makes the
  /// library provider always available.
  @override
  bool get isAvailable => true;

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return SearchResults.empty;

    // The contract is that a provider never throws — one unreachable source
    // must not empty a results page another source could have filled. The
    // repository already swallows its own failures; this is the second belt.
    final List<Track> tracks;
    try {
      tracks = await _catalog.searchTracks(trimmed, limit: limit);
    } on Object {
      return SearchResults.empty;
    }

    if (tracks.isEmpty) return SearchResults.empty;

    return SearchResults(
      tracks: Paging<Track>(
        items: tracks,
        total: tracks.length,
        limit: limit,
        offset: 0,
      ),
      // Artists and albums are deliberately empty, for the same reason
      // LibrarySearchProvider leaves them empty: AURIX stores an artist as a
      // display string on a song, not as a record with an id of its own, so an
      // "artist result" here would be a row that navigates nowhere. Returning
      // a dead row is worse than returning none.
      //
      // Playlists are absent too, and that is a different reason: playlists
      // live under `/users/{uid}` and are already streamed into memory in
      // full, so LibrarySearchProvider matches them instantly and offline. A
      // second query for them here would cost reads to find what the app is
      // already holding.
    );
  }
}
