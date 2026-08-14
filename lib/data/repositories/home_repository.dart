import 'dart:async';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/connectivity_service.dart';
import '../../core/storage/metadata_cache.dart';
import '../../core/utils/app_logger.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/category.dart';
import '../models/home_feed.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/spotify_browse_service.dart';
import '../services/spotify_playlist_service.dart';
import '../services/spotify_recommendation_service.dart';
import '../services/spotify_user_service.dart';

/// Builds the Home feed.
///
/// ## Design
///
/// Every shelf is fetched **concurrently and independently**. This is the
/// single most important property of this class: Spotify's endpoint
/// availability varies by app (see `SpotifyEndpoints.Restricted`), by account
/// (a brand-new account has no listening history) and by scope. A sequential
/// build would make Home as slow as the sum of its parts and as fragile as its
/// weakest endpoint.
///
/// Instead, a failing shelf resolves to an empty shelf, is dropped from the
/// render list, and the rest of the page loads normally. Every shelf that does
/// render contains live Spotify data.
class HomeRepository {
  HomeRepository({
    required SpotifyUserService userService,
    required SpotifyPlaylistService playlistService,
    required SpotifyBrowseService browseService,
    required SpotifyRecommendationService recommendationService,
    required MetadataCache cache,
    required ConnectivityService connectivity,
  }) : _users = userService,
       _playlists = playlistService,
       _browse = browseService,
       _recommendations = recommendationService,
       _cache = cache,
       _connectivity = connectivity;

  // The album and artist services are gone from this class along with the
  // `/browse/*` shelves that needed them. Every remaining shelf reads the
  // signed-in user's own data, which is one service.
  final SpotifyUserService _users;
  final SpotifyPlaylistService _playlists;
  final SpotifyBrowseService _browse;
  final SpotifyRecommendationService _recommendations;
  final MetadataCache _cache;
  final ConnectivityService _connectivity;

  /// Loads the feed.
  ///
  /// When offline, serves the cached feed with `isStale: true` rather than
  /// showing an error page over content the user could still browse.
  Future<HomeFeed> load({bool forceRefresh = false}) async {
    if (_connectivity.isOffline) {
      final cached = _readCache();
      if (cached != null) return cached.copyWith(isStale: true);
    }

    if (!forceRefresh) {
      final cached = _readCache();
      if (cached != null && _cache.isFresh(CacheKeys.homeFeed, ttl: AppConstants.homeCacheTtl)) {
        // Warm start: serve cache immediately, refresh in the background so
        // the next open is current without making this one wait.
        unawaited(_refreshInBackground());
        return cached;
      }
    }

    try {
      final feed = await _build();
      if (feed.visibleShelves.isNotEmpty) await _writeCache(feed);
      return feed;
    } on Object catch (error) {
      AppLogger.warn('Home build failed', scope: 'home', error: error);
      final cached = _readCache();
      if (cached != null) return cached.copyWith(isStale: true);
      rethrow;
    }
  }

  Future<void> _refreshInBackground() async {
    try {
      final feed = await _build();
      if (feed.visibleShelves.isNotEmpty) await _writeCache(feed);
    } on Object catch (error) {
      AppLogger.debug('Background home refresh failed: $error', scope: 'home');
    }
  }

  Future<HomeFeed> _build() async {
    // Every shelf starts at once. Each guard() swallows its own failure, so
    // Future.wait cannot be short-circuited by one bad endpoint.
    //
    // All of these are built from the signed-in user's own data — the only
    // endpoints a Development Mode application can reliably reach. Nothing
    // here calls `/browse/*` or `/recommendations`; those were removed rather
    // than retried. A shelf with no data resolves to empty and is dropped from
    // the render list, so a new account sees fewer sections rather than
    // error cards.
    final results = await Future.wait<HomeShelf>(<Future<HomeShelf>>[
      _recentlyPlayedShelf(),
      _madeForYouShelf(),
      _trendingShelf(),
      _recommendedShelf(),
      _popularArtistsShelf(),
      _likedSongsShelf(),
      _savedAlbumsShelf(),
      _followedArtistsShelf(),
      _moodShelf(),
    ]);

    return HomeFeed(shelves: results, generatedAt: DateTime.now());
  }

  // ---- Shelves -----------------------------------------------------------

  Future<HomeShelf> _recentlyPlayedShelf() => _guard(
    ShelfIds.recentlyPlayed,
    'Recently played',
    ShelfKind.tracks,
    () async {
      final page = await _users.recentlyPlayed(limit: 50);

      // `/recently-played` repeats a track for every play. Collapsing to the
      // most recent play per track is what makes this read as a shelf rather
      // than a log.
      final seen = <String>{};
      final tracks = <Track>[];
      for (final entry in page.items) {
        if (entry.track.id.isEmpty || !seen.add(entry.track.id)) continue;
        tracks.add(entry.track);
        if (tracks.length >= 12) break;
      }

      return HomeShelf.tracks(
        id: ShelfIds.recentlyPlayed,
        title: 'Recently played',
        items: tracks,
      );
    },
  );

  Future<HomeShelf> _madeForYouShelf() => _guard(
    ShelfIds.madeForYou,
    'Your playlists',
    ShelfKind.playlists,
    () async {
      // This used to try `/browse/featured-playlists` first and fall back to
      // the user's own playlists. The editorial endpoint has been restricted
      // since November 2024, so the fallback was the only path that ever ran
      // — it is now the only path there is.
      final mine = await _playlists.myPlaylists(limit: 12);
      return HomeShelf.playlists(
        id: ShelfIds.madeForYou,
        title: 'Your playlists',
        subtitle: 'Everything you follow',
        items: mine.items,
      );
    },
  );

  Future<HomeShelf> _trendingShelf() => _guard(
    ShelfIds.trending,
    'Trending for you',
    ShelfKind.tracks,
    () async {
      // Short term first — "on repeat lately" is the more interesting shelf.
      // A brand-new account has no short-term history, so widen the window
      // before giving up rather than reaching for a catalogue endpoint this
      // app cannot call.
      for (final range in const <TopItemRange>[
        TopItemRange.shortTerm,
        TopItemRange.mediumTerm,
        TopItemRange.longTerm,
      ]) {
        final page = await _users.topTracks(range: range, limit: 12);
        if (page.isEmpty) continue;

        return HomeShelf.tracks(
          id: ShelfIds.trending,
          title: range == TopItemRange.shortTerm
              ? 'Trending for you'
              : 'Your top tracks',
          subtitle: range == TopItemRange.shortTerm
              ? 'What you have had on repeat'
              : range.label,
          items: page.items,
        );
      }

      // No listening history at all. An empty shelf is dropped from the feed.
      return const HomeShelf(
        id: ShelfIds.trending,
        title: 'Trending for you',
        kind: ShelfKind.tracks,
      );
    },
  );

  Future<HomeShelf> _recommendedShelf() => _guard(
    ShelfIds.recommended,
    'Recommended',
    ShelfKind.tracks,
    () async {
      final tracks = await _recommendations.recommendedTracks(limit: 12);
      return HomeShelf.tracks(
        id: ShelfIds.recommended,
        title: 'Recommended for you',
        subtitle: 'Based on artists you listen to',
        items: tracks,
      );
    },
  );

  Future<HomeShelf> _popularArtistsShelf() => _guard(
    ShelfIds.popularArtists,
    'Popular artists',
    ShelfKind.artists,
    () async {
      // Same widening as the tracks shelf, and for the same reason: the
      // catalogue fallback this used to have is gone with `/browse/*`.
      for (final range in const <TopItemRange>[
        TopItemRange.mediumTerm,
        TopItemRange.shortTerm,
        TopItemRange.longTerm,
      ]) {
        final page = await _users.topArtists(range: range, limit: 12);
        if (page.isEmpty) continue;

        return HomeShelf.artists(
          id: ShelfIds.popularArtists,
          title: 'Your top artists',
          subtitle: range.label,
          items: page.items,
        );
      }

      return const HomeShelf(
        id: ShelfIds.popularArtists,
        title: 'Your top artists',
        kind: ShelfKind.artists,
      );
    },
  );

  /// Replaces the old "New releases" shelf, which was built on
  /// `/browse/new-releases`.
  Future<HomeShelf> _likedSongsShelf() => _guard(
    ShelfIds.likedSongs,
    'Liked songs',
    ShelfKind.tracks,
    () async {
      final page = await _users.savedTracks(limit: 12);
      return HomeShelf.tracks(
        id: ShelfIds.likedSongs,
        title: 'Liked songs',
        subtitle: 'Saved to your library',
        items: page.items.map((saved) => saved.track).toList(),
      );
    },
  );

  /// Replaces the old "Popular albums" shelf, which fell back to
  /// `/browse/new-releases` whenever the account had no listening history —
  /// i.e. exactly when it was needed.
  Future<HomeShelf> _savedAlbumsShelf() => _guard(
    ShelfIds.savedAlbums,
    'Your albums',
    ShelfKind.albums,
    () async {
      final albums = await _users.savedAlbumsFlat(limit: 16);
      return HomeShelf.albums(
        id: ShelfIds.savedAlbums,
        title: 'Your albums',
        subtitle: 'Saved to your library',
        items: albums,
      );
    },
  );

  Future<HomeShelf> _followedArtistsShelf() => _guard(
    ShelfIds.followedArtists,
    'Artists you follow',
    ShelfKind.artists,
    () async {
      final page = await _users.followedArtists(limit: 16);
      return HomeShelf.artists(
        id: ShelfIds.followedArtists,
        title: 'Artists you follow',
        items: page.items,
      );
    },
  );

  Future<HomeShelf> _moodShelf() => _guard(
    ShelfIds.moods,
    'Genres & moods',
    ShelfKind.categories,
    () async {
      final categories = await _browse.categories(limit: 16);
      return HomeShelf.categories(
        id: ShelfIds.moods,
        title: 'Genres & moods',
        items: categories,
      );
    },
  );

  /// Playlists behind a mood tile, loaded when the user taps one.
  Future<List<Playlist>> playlistsForCategory(Category category) =>
      _browse.categoryPlaylists(category, limit: 24);

  // ---- Plumbing ----------------------------------------------------------

  /// Runs a shelf builder, converting any failure into an empty shelf that
  /// carries a display-ready reason.
  Future<HomeShelf> _guard(
    String id,
    String title,
    ShelfKind kind,
    Future<HomeShelf> Function() build,
  ) async {
    try {
      return await build();
    } on ApiException catch (error) {
      AppLogger.info(
        'Shelf "$id" unavailable: ${error.kind.name} ${error.statusCode ?? ''}',
        scope: 'home',
      );
      return HomeShelf(id: id, title: title, kind: kind, error: error.message);
    } on Object catch (error, stackTrace) {
      AppLogger.error(
        'Shelf "$id" threw',
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

  // ---- Cache -------------------------------------------------------------

  HomeFeed? _readCache() {
    final entry = _cache.readList(CacheKeys.homeFeed);
    if (entry == null || entry.value.isEmpty) return null;
    try {
      final shelves = entry.value.map(_shelfFromJson).nonNulls.toList();
      if (shelves.isEmpty) return null;
      return HomeFeed(shelves: shelves, generatedAt: entry.storedAt);
    } on Object catch (error) {
      AppLogger.warn('Home cache unreadable', scope: 'home', error: error);
      return null;
    }
  }

  Future<void> _writeCache(HomeFeed feed) => _cache.writeList(
    CacheKeys.homeFeed,
    feed.visibleShelves.map(_shelfToJson).toList(),
  );

  Map<String, dynamic> _shelfToJson(HomeShelf shelf) => <String, dynamic>{
    'id': shelf.id,
    'title': shelf.title,
    'subtitle': shelf.subtitle,
    'kind': shelf.kind.name,
    'tracks': shelf.tracks.map((t) => t.toJson()).toList(),
    'albums': shelf.albums.map((a) => a.toJson()).toList(),
    'artists': shelf.artists.map((a) => a.toJson()).toList(),
    'playlists': shelf.playlists.map((p) => p.toJson()).toList(),
    'categories': shelf.categories.map((c) => c.toJson()).toList(),
  };

  HomeShelf? _shelfFromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final title = json['title'];
    final kindName = json['kind'];
    if (id is! String || title is! String || kindName is! String) return null;

    final kind = ShelfKind.values.where((k) => k.name == kindName).firstOrNull;
    if (kind == null) return null;

    List<T> parse<T>(String key, T Function(Map<String, dynamic>) from) {
      final raw = json[key];
      if (raw is! List) return const [];
      final out = <T>[];
      for (final entry in raw) {
        if (entry is! Map<String, dynamic>) continue;
        try {
          out.add(from(entry));
        } on Object {
          continue;
        }
      }
      return out;
    }

    return HomeShelf(
      id: id,
      title: title,
      subtitle: json['subtitle'] as String?,
      kind: kind,
      tracks: parse('tracks', Track.fromJson),
      albums: parse('albums', Album.fromJson),
      artists: parse('artists', Artist.fromJson),
      playlists: parse('playlists', Playlist.fromJson),
      categories: parse('categories', Category.fromJson),
    );
  }
}
