import 'dart:async';

import '../../core/utils/app_logger.dart';
import '../models/home_feed.dart';
import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/api/api_library_service.dart';
import '../services/api/api_playlist_service.dart';

/// Builds the Home feed from the user's own data.
///
/// ## What this used to be
///
/// Nine shelves, each an independent Spotify request, each wrapped in a guard
/// so that one restricted endpoint could not empty the page. Half of them
/// existed to work around Spotify's own restrictions: `/browse/featured-
/// playlists` had been unavailable to new apps since November 2024, `/browse/
/// new-releases` was replaced by "Your albums", and `/recommendations` needed a
/// listening history a new account did not have. The result was a page whose
/// contents depended on which endpoints the developer's Spotify application
/// happened to be allowed to call.
///
/// ## What it is now
///
/// Four shelves, all from Firestore, all belonging to the signed-in user. There
/// is no per-shelf failure to guard against — one database, one permission
/// model — and no cache to manage, because Firestore serves these from disk
/// when the network is gone.
///
/// The shelves are deliberately about *the user's own library* rather than a
/// catalogue. AURIX has no catalogue: what it has is what the user put in it,
/// so Home shows them that and nothing invented.
class HomeRepository {
  HomeRepository({
    required ApiLibraryService libraryService,
    required ApiPlaylistService playlistService,
  }) : _library = libraryService,
       _playlists = playlistService;

  final ApiLibraryService _library;
  final ApiPlaylistService _playlists;

  /// How many items a shelf carries. Enough to fill a horizontal carousel on a
  /// tablet without pulling the whole library to render twelve covers.
  static const int _shelfSize = 12;

  /// Builds the feed for [uid].
  ///
  /// Every shelf is fetched concurrently. That is worth keeping from the old
  /// implementation for a different reason than before: not because any one of
  /// them might fail, but because Firestore serves them from four independent
  /// listeners and awaiting them in sequence would make the page as slow as
  /// their sum for no benefit.
  ///
  /// An empty shelf is dropped from the render list rather than shown empty —
  /// see [HomeFeed.visibleShelves] — so a brand-new account sees fewer sections
  /// instead of a page of placeholders.
  Future<HomeFeed> load(String uid) async {
    final results = await Future.wait<HomeShelf>(<Future<HomeShelf>>[
      _recentlyPlayedShelf(uid),
      _likedSongsShelf(uid),
      _playlistsShelf(uid),
      _importedShelf(uid),
    ]);

    return HomeFeed(shelves: results, generatedAt: DateTime.now());
  }

  // ---- Shelves -----------------------------------------------------------

  Future<HomeShelf> _recentlyPlayedShelf(String uid) => _guard(
    ShelfIds.recentlyPlayed,
    'Recently played',
    ShelfKind.tracks,
    () async {
      final history = await _library.readRecentlyPlayed(uid, limit: _shelfSize);
      // No de-duplication pass here, unlike the Spotify version. The history
      // collection is keyed by track, so it is already one row per song — see
      // `ApiLibraryService.recordPlay`.
      return HomeShelf.tracks(
        id: ShelfIds.recentlyPlayed,
        title: 'Recently played',
        items: history.map((entry) => entry.track).toList(growable: false),
      );
    },
  );

  Future<HomeShelf> _likedSongsShelf(String uid) => _guard(
    ShelfIds.likedSongs,
    'Liked songs',
    ShelfKind.tracks,
    () async {
      final tracks = await _library.readLikedTracks(uid, limit: _shelfSize);
      return HomeShelf.tracks(
        id: ShelfIds.likedSongs,
        title: 'Liked songs',
        subtitle: 'Everything you have hearted',
        items: tracks,
      );
    },
  );

  Future<HomeShelf> _playlistsShelf(String uid) => _guard(
    ShelfIds.madeForYou,
    'Your playlists',
    ShelfKind.playlists,
    () async {
      final playlists = await _playlists.readPlaylists(uid);
      final own = playlists
          .where((playlist) => playlist.source == MediaSource.aurix)
          .take(_shelfSize)
          .toList(growable: false);
      return HomeShelf.playlists(
        id: ShelfIds.madeForYou,
        title: 'Your playlists',
        subtitle: 'Made in AURIX',
        items: own,
      );
    },
  );

  /// Playlists that came in from another service.
  ///
  /// A shelf of their own rather than mixed into "Your playlists", because the
  /// distinction is one the user made and can act on: these are the ones that
  /// re-importing will refresh.
  Future<HomeShelf> _importedShelf(String uid) => _guard(
    ShelfIds.imported,
    'Imported',
    ShelfKind.playlists,
    () async {
      final playlists = await _playlists.readPlaylists(uid);
      final imported = playlists
          .where((playlist) => playlist.source.isImported)
          .take(_shelfSize)
          .toList(growable: false);
      return HomeShelf.playlists(
        id: ShelfIds.imported,
        title: 'Imported playlists',
        subtitle: 'Brought in from another service',
        items: imported,
      );
    },
  );

  // ---- Plumbing ----------------------------------------------------------

  /// Runs a shelf builder, converting any failure into an empty shelf.
  ///
  /// Kept from the Spotify implementation even though the failure it was built
  /// for is gone. A different one replaced it: a Firestore query whose security
  /// rules or composite index are wrong fails at runtime, and a Home screen
  /// that shows three shelves and logs the fourth is far easier to diagnose
  /// than one that shows an error page for the whole feed.
  Future<HomeShelf> _guard(
    String id,
    String title,
    ShelfKind kind,
    Future<HomeShelf> Function() build,
  ) async {
    try {
      return await build();
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Home shelf "$id" failed',
        scope: 'home',
        error: error,
        stackTrace: stackTrace,
      );
      return HomeShelf(
        id: id,
        title: title,
        kind: kind,
        error: 'This section is unavailable right now.',
      );
    }
  }
}

/// Shelf builders that take data the caller already has.
///
/// The Home screen watches the same Firestore streams the Library screen does,
/// so it usually has the tracks and playlists in hand before it asks for a
/// feed. These build the shelves from that rather than re-reading — the whole
/// feed becomes a pure function of state already in memory, and Home updates
/// the instant a like lands rather than on the next refresh.
abstract final class HomeShelves {
  static HomeShelf recentlyPlayed(List<Track> tracks) => HomeShelf.tracks(
    id: ShelfIds.recentlyPlayed,
    title: 'Recently played',
    items: tracks.take(HomeRepository._shelfSize).toList(growable: false),
  );

  static HomeShelf likedSongs(List<Track> tracks) => HomeShelf.tracks(
    id: ShelfIds.likedSongs,
    title: 'Liked songs',
    subtitle: 'Everything you have hearted',
    items: tracks.take(HomeRepository._shelfSize).toList(growable: false),
  );

  static HomeShelf ownPlaylists(List<Playlist> playlists) => HomeShelf.playlists(
    id: ShelfIds.madeForYou,
    title: 'Your playlists',
    subtitle: 'Made in AURIX',
    items: playlists
        .where((playlist) => playlist.source == MediaSource.aurix)
        .take(HomeRepository._shelfSize)
        .toList(growable: false),
  );

  static HomeShelf imported(List<Playlist> playlists) => HomeShelf.playlists(
    id: ShelfIds.imported,
    title: 'Imported playlists',
    subtitle: 'Brought in from another service',
    items: playlists
        .where((playlist) => playlist.source.isImported)
        .take(HomeRepository._shelfSize)
        .toList(growable: false),
  );

  /// Recently added to the library — the newest liked tracks.
  ///
  /// Distinct from "Liked songs" by ordering only, and that is enough to earn
  /// its place: the liked shelf is a way in to the whole collection, this one
  /// answers "what did I add this week".
  static HomeShelf recentlyAdded(List<Track> liked) => HomeShelf.tracks(
    id: ShelfIds.recentlyAdded,
    title: 'Recently added',
    subtitle: 'The newest things in your library',
    items: liked.take(HomeRepository._shelfSize).toList(growable: false),
  );
}
