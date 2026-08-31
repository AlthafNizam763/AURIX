import 'dart:async';

import '../models/paging.dart';
import '../models/playlist.dart';
import '../models/search_results.dart';
import '../repositories/playlist_catalog_repository.dart';
import 'search_provider.dart';

/// Searches the shared AURIX playlist catalogue.
///
/// ## The provider that makes a shared import discoverable
///
/// Without it, an imported playlist is reachable only by the account that
/// imported it: [LibrarySearchProvider] matches the playlists already streamed
/// into memory, and those are the signed-in user's own. User A importing "Love"
/// and User C searching "love" would find nothing — precisely the behaviour the
/// shared catalogue exists to fix.
///
/// This closes that gap. Every playlist any account has imported is a document
/// in `/playlists`, and this queries it with no uid filter of any kind, so the
/// same query returns the same playlists for every signed-in user.
///
/// ## It searches AURIX, not Spotify
///
/// Worth stating because a class it sits beside does the opposite.
/// `SpotifySearchProvider` asks Spotify's `/search` and is available only while
/// a Spotify session is live. This asks Firestore, needs no third-party
/// credentials, and — because Firestore serves queries from its local cache —
/// keeps answering when the network is gone.
///
/// ## Priority
///
/// 40: below the library (0), above the song catalogue (50) and any external
/// source (100+). The ordering is a claim about usefulness, and the library
/// winning matters here for a specific reason rather than a general one — a
/// playlist the user imported themselves appears in *both* providers, and
/// merging the library's copy first is what stops it being listed twice. See
/// `SearchResults.merge`, which de-duplicates by id.
class PlaylistCatalogSearchProvider implements SearchProvider {
  PlaylistCatalogSearchProvider({required PlaylistCatalogRepository catalog})
      : _catalog = catalog;

  final PlaylistCatalogRepository _catalog;

  @override
  String get displayName => 'AURIX playlists';

  @override
  int get priority => 40;

  /// Always. It needs no session and no network — Firestore answers from its
  /// local cache when offline, the same property that makes the library and
  /// song-catalogue providers always available.
  @override
  bool get isAvailable => true;

  @override
  Future<SearchResults> search(String query, {int limit = 20}) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return SearchResults.empty;

    // The contract is that a provider never throws — one unreachable source
    // must not empty a results page another source could have filled. The
    // service already swallows its own failures; this is the second belt.
    final List<Playlist> playlists;
    try {
      playlists = await _catalog.search(trimmed, limit: limit);
    } on Object {
      return SearchResults.empty;
    }

    if (playlists.isEmpty) return SearchResults.empty;

    return SearchResults(
      playlists: Paging<Playlist>(
        items: playlists,
        total: playlists.length,
        limit: limit,
        offset: 0,
      ),
      // Tracks are deliberately absent. A playlist's songs are already in
      // `/catalog/songs` and `CatalogSearchProvider` finds them there; querying
      // every matching playlist's subcollection here would be a read per song
      // to return rows that provider already returns.
    );
  }
}
