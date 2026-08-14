import 'package:equatable/equatable.dart';

import 'album.dart';
import 'artist.dart';
import 'json_utils.dart';
import 'paging.dart';
import 'playlist.dart';
import 'track.dart';

/// The search result categories AURIX supports.
///
/// `show` and `episode` are deliberately excluded: AURIX is a music client
/// and has no screen that can do anything useful with a podcast.
enum SearchType {
  track,
  artist,
  album,
  playlist;

  /// The types the main search screen requests.
  ///
  /// `playlist` is excluded. Since Spotify's 2024 changes a playlist search
  /// returns mostly `null` entries to a Development Mode application — the
  /// paging parser drops them, so the tab renders empty no matter what is
  /// typed, which reads as a broken feature rather than an unavailable one.
  /// The type is still supported by [SpotifySearchService] because the genre
  /// tiles depend on it and degrade to an empty grid rather than a dead tab.
  static const List<SearchType> browsable = <SearchType>[
    SearchType.track,
    SearchType.artist,
    SearchType.album,
  ];

  /// Value for the `type` query parameter.
  String get apiValue => name;

  String get label {
    switch (this) {
      case SearchType.track:
        return 'Songs';
      case SearchType.artist:
        return 'Artists';
      case SearchType.album:
        return 'Albums';
      case SearchType.playlist:
        return 'Playlists';
    }
  }
}

/// A `GET /search` response.
///
/// Each section is independently paged by Spotify, so each keeps its own
/// [Paging] rather than being flattened — that is what lets the Songs tab
/// load page 3 while the Artists tab is still on page 1.
class SearchResults extends Equatable {
  const SearchResults({
    this.tracks = const Paging<Track>(items: [], total: 0, limit: 0, offset: 0),
    this.artists = const Paging<Artist>(items: [], total: 0, limit: 0, offset: 0),
    this.albums = const Paging<Album>(items: [], total: 0, limit: 0, offset: 0),
    this.playlists = const Paging<Playlist>(items: [], total: 0, limit: 0, offset: 0),
  });

  final Paging<Track> tracks;
  final Paging<Artist> artists;
  final Paging<Album> albums;
  final Paging<Playlist> playlists;

  static const SearchResults empty = SearchResults();

  factory SearchResults.fromJson(Map<String, dynamic> json) {
    final tracks = Json.obj(json, 'tracks');
    final artists = Json.obj(json, 'artists');
    final albums = Json.obj(json, 'albums');
    final playlists = Json.obj(json, 'playlists');

    return SearchResults(
      tracks: tracks == null
          ? Paging.empty<Track>()
          : Paging<Track>.fromJson(tracks, Track.fromJson),
      artists: artists == null
          ? Paging.empty<Artist>()
          : Paging<Artist>.fromJson(artists, Artist.fromJson),
      albums: albums == null
          ? Paging.empty<Album>()
          : Paging<Album>.fromJson(albums, Album.fromJson),
      // Spotify has been observed returning null entries inside the playlist
      // items array; Json.list already drops them.
      playlists: playlists == null
          ? Paging.empty<Playlist>()
          : Paging<Playlist>.fromJson(playlists, Playlist.fromJson),
    );
  }

  bool get isEmpty =>
      tracks.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty;

  bool get isNotEmpty => !isEmpty;

  int get totalCount =>
      tracks.items.length +
      artists.items.length +
      albums.items.length +
      playlists.items.length;

  /// The section types that actually returned something, in display order.
  List<SearchType> get populatedTypes => <SearchType>[
    if (tracks.isNotEmpty) SearchType.track,
    if (artists.isNotEmpty) SearchType.artist,
    if (albums.isNotEmpty) SearchType.album,
    if (playlists.isNotEmpty) SearchType.playlist,
  ];

  /// The single most relevant hit across all sections, used for the large
  /// "Top result" card. Spotify orders each section by relevance, so the best
  /// candidate is the head of the highest-confidence section.
  Object? get topResult {
    if (artists.isNotEmpty && (artists.items.first.popularity ?? 0) >= 60) {
      return artists.items.first;
    }
    if (tracks.isNotEmpty) return tracks.items.first;
    if (artists.isNotEmpty) return artists.items.first;
    if (albums.isNotEmpty) return albums.items.first;
    if (playlists.isNotEmpty) return playlists.items.first;
    return null;
  }

  /// Merges a newly-loaded page into the matching section.
  SearchResults appendPage(SearchType type, SearchResults page) {
    switch (type) {
      case SearchType.track:
        return copyWith(tracks: tracks.append(page.tracks));
      case SearchType.artist:
        return copyWith(artists: artists.append(page.artists));
      case SearchType.album:
        return copyWith(albums: albums.append(page.albums));
      case SearchType.playlist:
        return copyWith(playlists: playlists.append(page.playlists));
    }
  }

  Paging<Object> pageFor(SearchType type) {
    switch (type) {
      case SearchType.track:
        return tracks.map<Object>((t) => t);
      case SearchType.artist:
        return artists.map<Object>((a) => a);
      case SearchType.album:
        return albums.map<Object>((a) => a);
      case SearchType.playlist:
        return playlists.map<Object>((p) => p);
    }
  }

  SearchResults copyWith({
    Paging<Track>? tracks,
    Paging<Artist>? artists,
    Paging<Album>? albums,
    Paging<Playlist>? playlists,
  }) => SearchResults(
    tracks: tracks ?? this.tracks,
    artists: artists ?? this.artists,
    albums: albums ?? this.albums,
    playlists: playlists ?? this.playlists,
  );

  @override
  List<Object?> get props => [tracks, artists, albums, playlists];
}
