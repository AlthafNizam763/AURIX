import 'dart:async';

import '../../core/network/connectivity_service.dart';
import '../../core/storage/metadata_cache.dart';
import '../../core/utils/app_logger.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/playlist.dart';
import '../models/saved_item.dart';
import '../models/track.dart';
import '../services/spotify_playlist_service.dart';
import '../services/spotify_user_service.dart';

/// The user's saved content.
class LibrarySnapshot {
  const LibrarySnapshot({
    this.likedTracks = const [],
    this.savedAlbums = const [],
    this.followedArtists = const [],
    this.playlists = const [],
    this.recentlyPlayed = const [],
    this.isStale = false,
  });

  final List<SavedTrack> likedTracks;
  final List<SavedAlbum> savedAlbums;
  final List<Artist> followedArtists;
  final List<Playlist> playlists;
  final List<PlayHistoryEntry> recentlyPlayed;
  final bool isStale;

  bool get isEmpty =>
      likedTracks.isEmpty &&
      savedAlbums.isEmpty &&
      followedArtists.isEmpty &&
      playlists.isEmpty;

  LibrarySnapshot copyWith({
    List<SavedTrack>? likedTracks,
    List<SavedAlbum>? savedAlbums,
    List<Artist>? followedArtists,
    List<Playlist>? playlists,
    List<PlayHistoryEntry>? recentlyPlayed,
  }) => LibrarySnapshot(
    likedTracks: likedTracks ?? this.likedTracks,
    savedAlbums: savedAlbums ?? this.savedAlbums,
    followedArtists: followedArtists ?? this.followedArtists,
    playlists: playlists ?? this.playlists,
    recentlyPlayed: recentlyPlayed ?? this.recentlyPlayed,
    isStale: isStale,
  );
}

/// Reads and writes the user's library.
///
/// Save/unsave operations are optimistic at the provider layer; this class is
/// responsible for the network truth and for keeping the cache consistent, so
/// a failed write can be rolled back cleanly.
class LibraryRepository {
  LibraryRepository({
    required SpotifyUserService userService,
    required SpotifyPlaylistService playlistService,
    required MetadataCache cache,
    required ConnectivityService connectivity,
  }) : _users = userService,
       _playlists = playlistService,
       _cache = cache,
       _connectivity = connectivity;

  final SpotifyUserService _users;
  final SpotifyPlaylistService _playlists;
  final MetadataCache _cache;
  final ConnectivityService _connectivity;

  /// How much of the library is pulled up front. Enough to fill the screen and
  /// support local search/sort without pulling a 5,000-track library on open.
  static const int _initialPageSize = 50;

  Future<LibrarySnapshot> load({bool forceRefresh = false}) async {
    if (_connectivity.isOffline) {
      final cached = _readCache();
      if (cached != null) return cached;
    }

    final results = await Future.wait<Object>(<Future<Object>>[
      _users
          .savedTracks(limit: _initialPageSize)
          .then<List<SavedTrack>>((p) => p.items)
          .catchError(_emptyOn<List<SavedTrack>>('liked tracks', const [])),
      _users
          .savedAlbums(limit: _initialPageSize)
          .then<List<SavedAlbum>>((p) => p.items)
          .catchError(_emptyOn<List<SavedAlbum>>('saved albums', const [])),
      _users
          .followedArtists(limit: _initialPageSize)
          .then<List<Artist>>((p) => p.items)
          .catchError(_emptyOn<List<Artist>>('followed artists', const [])),
      _playlists
          .myPlaylists(limit: _initialPageSize)
          .then<List<Playlist>>((p) => p.items)
          .catchError(_emptyOn<List<Playlist>>('playlists', const [])),
      _users
          .recentlyPlayed(limit: 50)
          .then<List<PlayHistoryEntry>>((p) => p.items)
          .catchError(_emptyOn<List<PlayHistoryEntry>>('recently played', const [])),
    ]);

    final snapshot = LibrarySnapshot(
      likedTracks: results[0] as List<SavedTrack>,
      savedAlbums: results[1] as List<SavedAlbum>,
      followedArtists: results[2] as List<Artist>,
      playlists: results[3] as List<Playlist>,
      recentlyPlayed: results[4] as List<PlayHistoryEntry>,
    );

    unawaited(_writeCache(snapshot));
    return snapshot;
  }

  /// Paging for the Liked Songs screen, which can run to thousands of rows.
  Future<List<SavedTrack>> moreLikedTracks({required int offset, int limit = 50}) async {
    final page = await _users.savedTracks(limit: limit, offset: offset);
    return page.items;
  }

  Future<List<SavedAlbum>> moreSavedAlbums({required int offset, int limit = 50}) async {
    final page = await _users.savedAlbums(limit: limit, offset: offset);
    return page.items;
  }

  Future<List<Playlist>> morePlaylists({required int offset, int limit = 50}) async {
    final page = await _playlists.myPlaylists(limit: limit, offset: offset);
    return page.items;
  }

  Future<List<Artist>> moreFollowedArtists({String? after, int limit = 50}) async {
    final page = await _users.followedArtists(limit: limit, after: after);
    return page.items;
  }

  // ---- Mutations ---------------------------------------------------------

  Future<void> saveTrack(Track track) => _users.saveTracks(<String>[track.id]);
  Future<void> unsaveTrack(Track track) => _users.removeTracks(<String>[track.id]);

  Future<void> saveAlbum(Album album) => _users.saveAlbums(<String>[album.id]);
  Future<void> unsaveAlbum(Album album) => _users.removeAlbums(<String>[album.id]);

  Future<void> followArtist(Artist artist) =>
      _users.followArtists(<String>[artist.id]);
  Future<void> unfollowArtist(Artist artist) =>
      _users.unfollowArtists(<String>[artist.id]);

  Future<void> savePlaylist(Playlist playlist) => _playlists.follow(playlist.id);
  Future<void> unsavePlaylist(Playlist playlist) =>
      _playlists.unfollow(playlist.id);

  // ---- Membership checks -------------------------------------------------

  Future<List<bool>> areTracksSaved(List<String> ids) => _users.areTracksSaved(ids);
  Future<List<bool>> areAlbumsSaved(List<String> ids) => _users.areAlbumsSaved(ids);
  Future<List<bool>> areArtistsFollowed(List<String> ids) =>
      _users.areArtistsFollowed(ids);

  /// Batched membership lookup for a track list.
  ///
  /// Returns a set of the saved IDs rather than a positional list, so callers
  /// cannot silently mis-align it with their rows.
  Future<Set<String>> savedTrackIds(List<String> ids) async {
    if (ids.isEmpty) return const {};
    try {
      final flags = await _users.areTracksSaved(ids);
      final saved = <String>{};
      for (var i = 0; i < ids.length && i < flags.length; i++) {
        if (flags[i]) saved.add(ids[i]);
      }
      return saved;
    } on Object catch (error) {
      AppLogger.debug('Saved-track lookup failed: $error', scope: 'library');
      return const {};
    }
  }

  // ---- Cache -------------------------------------------------------------

  LibrarySnapshot? _readCache() {
    List<T> read<T>(String key, T Function(Map<String, dynamic>) parse) {
      final entry = _cache.readList(key);
      if (entry == null) return const [];
      final out = <T>[];
      for (final row in entry.value) {
        try {
          out.add(parse(row));
        } on Object {
          continue;
        }
      }
      return out;
    }

    final liked = read(CacheKeys.likedTracks, SavedTrack.fromJson);
    final albums = read(CacheKeys.savedAlbums, SavedAlbum.fromJson);
    final artists = read(CacheKeys.followedArtists, Artist.fromJson);
    final playlists = read(CacheKeys.userPlaylists, Playlist.fromJson);
    final recent = read(CacheKeys.recentlyPlayed, PlayHistoryEntry.fromJson);

    if (liked.isEmpty && albums.isEmpty && artists.isEmpty && playlists.isEmpty) {
      return null;
    }

    return LibrarySnapshot(
      likedTracks: liked,
      savedAlbums: albums,
      followedArtists: artists,
      playlists: playlists,
      recentlyPlayed: recent,
      isStale: true,
    );
  }

  Future<void> _writeCache(LibrarySnapshot snapshot) async {
    // Capped so the preferences blob stays small — SharedPreferences is not a
    // database, and a 5,000-track library serialised into it would stall the
    // platform channel on every write.
    await _cache.writeList(
      CacheKeys.likedTracks,
      snapshot.likedTracks.take(100).map((t) => t.toJson()).toList(),
    );
    await _cache.writeList(
      CacheKeys.savedAlbums,
      snapshot.savedAlbums.take(100).map((a) => a.toJson()).toList(),
    );
    await _cache.writeList(
      CacheKeys.followedArtists,
      snapshot.followedArtists.take(100).map((a) => a.toJson()).toList(),
    );
    await _cache.writeList(
      CacheKeys.userPlaylists,
      snapshot.playlists.take(100).map((p) => p.toJson()).toList(),
    );
    await _cache.writeList(
      CacheKeys.recentlyPlayed,
      snapshot.recentlyPlayed.take(50).map((e) => e.toJson()).toList(),
    );
  }

  /// Builds a `catchError` handler that logs and yields a default, so one
  /// missing scope cannot empty the whole Library screen.
  Future<T> Function(Object) _emptyOn<T>(String label, T fallback) =>
      (Object error) async {
        AppLogger.info('Library section "$label" unavailable: $error', scope: 'library');
        return fallback;
      };
}
