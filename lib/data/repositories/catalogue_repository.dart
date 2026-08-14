import 'dart:async';

import '../../core/network/connectivity_service.dart';
import '../../core/storage/metadata_cache.dart';
import '../../core/utils/app_logger.dart';
import '../models/album.dart';
import '../models/artist.dart';
import '../models/paging.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/spotify_album_service.dart';
import '../services/spotify_artist_service.dart';
import '../services/spotify_playlist_service.dart';
import '../services/spotify_recommendation_service.dart';

/// Everything an artist screen needs, resolved in one call.
class ArtistDetail {
  const ArtistDetail({
    required this.artist,
    this.topTracks = const [],
    this.albums = const [],
    this.singles = const [],
    this.appearsOn = const [],
    this.relatedArtists = const [],
    this.isFollowed = false,
    this.isStale = false,
  });

  final Artist artist;
  final List<Track> topTracks;
  final List<Album> albums;
  final List<Album> singles;
  final List<Album> appearsOn;
  final List<Artist> relatedArtists;
  final bool isFollowed;
  final bool isStale;

  ArtistDetail copyWith({bool? isFollowed}) => ArtistDetail(
    artist: artist,
    topTracks: topTracks,
    albums: albums,
    singles: singles,
    appearsOn: appearsOn,
    relatedArtists: relatedArtists,
    isFollowed: isFollowed ?? this.isFollowed,
    isStale: isStale,
  );
}

class AlbumDetail {
  const AlbumDetail({
    required this.album,
    this.isSaved = false,
    this.isStale = false,
  });

  final Album album;
  final bool isSaved;
  final bool isStale;

  List<Track> get tracks => album.tracks?.items ?? const [];

  AlbumDetail copyWith({bool? isSaved}) =>
      AlbumDetail(album: album, isSaved: isSaved ?? this.isSaved, isStale: isStale);
}

/// What happened when the playlist's contents were asked for.
///
/// Four outcomes that a single "is the list empty?" check used to flatten into
/// one, which is how a playlist Spotify refused to enumerate ended up rendering
/// as "This playlist is empty".
enum PlaylistItemsStatus {
  /// Contents resolved and there is at least one entry.
  loaded,

  /// Contents resolved and the playlist genuinely has nothing in it.
  empty,

  /// Spotify would not serve the contents to this application. The playlist
  /// itself loaded, so its name, cover and follower count are still valid.
  unavailable,
}

class PlaylistDetail {
  const PlaylistDetail({
    required this.playlist,
    this.isSaved,
    this.isEditable = false,
    this.isStale = false,
  });

  final Playlist playlist;

  /// Null when Spotify declined to say — see `SpotifyPlaylistService
  /// .isFollowing`. Distinct from false, which is a positive claim that the
  /// user has not saved this playlist.
  final bool? isSaved;

  final bool isEditable;
  final bool isStale;

  List<PlaylistItem> get items => playlist.items?.items ?? const [];

  /// `Playlist.items` is null only when the contents could not be fetched;
  /// a playlist that resolved to nothing carries an empty page instead.
  PlaylistItemsStatus get itemsStatus {
    final page = playlist.items;
    if (page == null) return PlaylistItemsStatus.unavailable;
    return page.items.isEmpty
        ? PlaylistItemsStatus.empty
        : PlaylistItemsStatus.loaded;
  }

  /// The count to render. Prefers the contents page's own total, which is
  /// present even when the detail response omitted its summary count.
  int get trackTotal {
    final page = playlist.items;
    if (page != null && page.total > 0) return page.total;
    return playlist.trackCount;
  }

  PlaylistDetail copyWith({
    Playlist? playlist,
    bool? isSaved,
  }) => PlaylistDetail(
    playlist: playlist ?? this.playlist,
    isSaved: isSaved ?? this.isSaved,
    isEditable: isEditable,
    isStale: isStale,
  );
}

/// Reads for albums, artists and playlists.
///
/// Each detail load fans out into several parallel requests and caches the
/// result, so revisiting an album from the mini player is instant and works
/// offline. Library membership (`isSaved`, `isFollowed`) is folded in here
/// because a save button that renders in the wrong state for a beat is one of
/// the most visible ways a music app feels cheap.
class CatalogueRepository {
  CatalogueRepository({
    required SpotifyAlbumService albumService,
    required SpotifyArtistService artistService,
    required SpotifyPlaylistService playlistService,
    required SpotifyRecommendationService recommendationService,
    required MetadataCache cache,
    required ConnectivityService connectivity,
  }) : _albums = albumService,
       _artists = artistService,
       _playlists = playlistService,
       _recommendations = recommendationService,
       _cache = cache,
       _connectivity = connectivity;

  final SpotifyAlbumService _albums;
  final SpotifyArtistService _artists;
  final SpotifyPlaylistService _playlists;
  final SpotifyRecommendationService _recommendations;
  final MetadataCache _cache;
  final ConnectivityService _connectivity;

  // The two library-membership callbacks that used to be injected here are
  // gone: `areAlbumsSaved` and `areArtistsFollowed` asked Spotify whether the
  // user had saved an album or followed an artist, and AURIX's library holds
  // neither. `AlbumDetail.isSaved` and `ArtistDetail.isFollowed` are therefore
  // always false — kept on the models so the screens keep compiling while
  // their save/follow controls are removed, and slated for deletion with the
  // rest of the Spotify catalogue layer.

  // ---- Album -------------------------------------------------------------

  Future<AlbumDetail> album(String id, {bool forceRefresh = false}) async {
    if (_connectivity.isOffline || !forceRefresh) {
      final cached = _cachedAlbum(id);
      if (cached != null && (_connectivity.isOffline || _cache.isFresh(CacheKeys.album(id)))) {
        return AlbumDetail(album: cached, isStale: _connectivity.isOffline);
      }
    }

    final album = await _albums.albumWithAllTracks(id);
    unawaited(_cache.writeObject(CacheKeys.album(id), album.toJson()));

    return AlbumDetail(album: album);
  }

  Album? _cachedAlbum(String id) {
    final entry = _cache.readObject(CacheKeys.album(id));
    if (entry == null) return null;
    try {
      return Album.fromJson(entry.value);
    } on Object {
      return null;
    }
  }

  // ---- Artist ------------------------------------------------------------

  Future<ArtistDetail> artist(String id, {bool forceRefresh = false}) async {
    if (_connectivity.isOffline) {
      final cached = _cachedArtist(id);
      if (cached != null) return ArtistDetail(artist: cached, isStale: true);
    }

    // The artist record is needed first: related-artist search seeds from its
    // genres, so that one request cannot be parallelised with the rest.
    final artist = await _artists.artist(id);
    unawaited(_cache.writeObject(CacheKeys.artist(id), artist.toJson()));

    final results = await Future.wait<Object>(<Future<Object>>[
      _artists.topTracks(id).catchError((Object _) => const <Track>[]),
      _artists
          .albums(id, limit: 20)
          .catchError((Object _) => Paging.empty<Album>()),
      _artists
          .singles(id, limit: 20)
          .catchError((Object _) => Paging.empty<Album>()),
      _artists
          .appearsOn(id, limit: 12)
          .catchError((Object _) => Paging.empty<Album>()),
      _artists
          .relatedArtists(
            id,
            genreHints: artist.genres,
            excludeName: artist.name,
          )
          .catchError((Object _) => const <Artist>[]),
    ]);

    return ArtistDetail(
      artist: artist,
      topTracks: results[0] as List<Track>,
      albums: (results[1] as Paging<Album>).items,
      singles: (results[2] as Paging<Album>).items,
      appearsOn: (results[3] as Paging<Album>).items,
      relatedArtists: results[4] as List<Artist>,
    );
  }

  Artist? _cachedArtist(String id) {
    final entry = _cache.readObject(CacheKeys.artist(id));
    if (entry == null) return null;
    try {
      return Artist.fromJson(entry.value);
    } on Object {
      return null;
    }
  }

  /// Next page of an artist's discography, for infinite scroll.
  Future<Paging<Album>> moreArtistAlbums(
    String id, {
    required AlbumType group,
    required int offset,
    int limit = 20,
  }) => _artists.albums(id, groups: <AlbumType>[group], limit: limit, offset: offset);

  Future<List<Track>> similarTracks(Artist artist, {int limit = 20}) =>
      _recommendations.similarToArtist(artist, limit: limit);

  // ---- Playlist ----------------------------------------------------------

  Future<PlaylistDetail> playlist(
    String id, {
    String? currentUserId,
    bool forceRefresh = false,
  }) async {
    if (_connectivity.isOffline) {
      final cached = _cachedPlaylist(id);
      if (cached != null) {
        return PlaylistDetail(
          playlist: cached,
          isEditable: cached.isEditableBy(currentUserId),
          isStale: true,
        );
      }
    }

    final playlist = await _playlists.playlistWithTracks(id);
    // Only cache a playlist whose contents actually resolved. Writing one that
    // Spotify refused would persist the empty-looking shape and serve it back
    // on the next visit without even retrying.
    if (playlist.items != null) {
      unawaited(_cache.writeObject(CacheKeys.playlist(id), playlist.toJson()));
    }

    // Null means "Spotify would not say" — carried through rather than
    // collapsed to false, so the UI can render an indeterminate heart instead
    // of asserting the playlist is not saved.
    bool? isSaved;
    if (currentUserId != null) {
      // A playlist the user owns is implicitly "saved"; asking Spotify would
      // return false and render a misleading empty heart.
      isSaved = playlist.owner?.id == currentUserId
          ? true
          : await _safeFollowState(() => _playlists.isFollowing(id));
    }

    return PlaylistDetail(
      playlist: playlist,
      isSaved: isSaved,
      isEditable: playlist.isEditableBy(currentUserId),
    );
  }

  /// Runs a follow lookup, keeping "unknown" distinct from "not followed".
  Future<bool?> _safeFollowState(Future<bool?> Function() lookup) async {
    try {
      return await lookup();
    } on Object catch (error) {
      AppLogger.debug('Follow lookup failed: $error', scope: 'catalogue');
      return null;
    }
  }

  Playlist? _cachedPlaylist(String id) {
    final entry = _cache.readObject(CacheKeys.playlist(id));
    if (entry == null) return null;
    try {
      return Playlist.fromJson(entry.value);
    } on Object {
      return null;
    }
  }

  /// Next page of a playlist's contents.
  ///
  /// Null means Spotify refused the page rather than that there are no more —
  /// the pager stops asking on a refusal instead of retrying it on every
  /// scroll frame.
  Future<Paging<PlaylistItem>?> morePlaylistItems(
    String id, {
    required int offset,
    int limit = 50,
  }) => _playlists.playlistItemsPage(id, limit: limit, offset: offset);

  // ---- Playlist mutations ------------------------------------------------

  /// Removes a track from a **Spotify-hosted** playlist.
  ///
  /// Retained for the Spotify import path only; AURIX playlists live in
  /// Firestore and are edited through `FirestorePlaylistService`. A track with
  /// no Spotify id cannot be addressed here at all, which is why this returns
  /// null rather than attempting the call — a synthesised
  /// `spotify:track:aurix_slug` would be rejected by Spotify as a malformed
  /// request several layers from the cause.
  Future<String?> removeFromPlaylist(
    String playlistId,
    Track track, {
    String? snapshotId,
  }) {
    final uri = track.spotifyUri;
    if (uri == null) return Future<String?>.value();
    return _playlists.removeTracks(
      playlistId,
      <String>[uri],
      snapshotId: snapshotId,
    );
  }

  /// Adds tracks to a **Spotify-hosted** playlist. See [removeFromPlaylist].
  ///
  /// Tracks with no Spotify id are skipped rather than failing the batch: a
  /// mixed selection should add what it can, and the caller is told how many
  /// landed by the snapshot it gets back.
  Future<String?> addToPlaylist(String playlistId, List<Track> tracks) {
    final uris = tracks.map((t) => t.spotifyUri).nonNulls.toList(growable: false);
    if (uris.isEmpty) return Future<String?>.value();
    return _playlists.addTracks(playlistId, uris);
  }

  Future<String?> reorderPlaylist(
    String playlistId, {
    required int from,
    required int to,
    String? snapshotId,
  }) => _playlists.reorder(
    playlistId,
    from: from,
    to: to,
    snapshotId: snapshotId,
  );

  // ---- Helpers -----------------------------------------------------------

  /// Library membership is decoration on a detail screen. If the lookup fails
  /// (missing scope, offline), render the screen with the control in its
  /// default state rather than failing the whole load.
}
