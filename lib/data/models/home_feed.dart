import 'package:equatable/equatable.dart';

import 'album.dart';
import 'artist.dart';
import 'category.dart';
import 'playlist.dart';
import 'track.dart';

/// What a home shelf contains, which decides how it renders and where a tap
/// navigates.
enum ShelfKind { tracks, albums, artists, playlists, categories }

/// One horizontal shelf on the Home screen.
///
/// Shelves are built independently and are allowed to fail independently:
/// [error] carries a per-shelf failure so a 403 on one endpoint hides that
/// shelf instead of blanking the whole page. That is what makes Home resilient
/// to Spotify's per-app endpoint availability differences.
class HomeShelf extends Equatable {
  const HomeShelf({
    required this.id,
    required this.title,
    required this.kind,
    this.subtitle,
    this.tracks = const [],
    this.albums = const [],
    this.artists = const [],
    this.playlists = const [],
    this.categories = const [],
    this.error,
  });

  final String id;
  final String title;
  final String? subtitle;
  final ShelfKind kind;

  final List<Track> tracks;
  final List<Album> albums;
  final List<Artist> artists;
  final List<Playlist> playlists;
  final List<Category> categories;

  /// User-facing reason this shelf is empty, when it failed rather than
  /// simply having nothing to show. Never a raw exception string.
  final String? error;

  const HomeShelf.tracks({
    required this.id,
    required this.title,
    required List<Track> items,
    this.subtitle,
    this.error,
  }) : kind = ShelfKind.tracks,
       tracks = items,
       albums = const [],
       artists = const [],
       playlists = const [],
       categories = const [];

  const HomeShelf.albums({
    required this.id,
    required this.title,
    required List<Album> items,
    this.subtitle,
    this.error,
  }) : kind = ShelfKind.albums,
       albums = items,
       tracks = const [],
       artists = const [],
       playlists = const [],
       categories = const [];

  const HomeShelf.artists({
    required this.id,
    required this.title,
    required List<Artist> items,
    this.subtitle,
    this.error,
  }) : kind = ShelfKind.artists,
       artists = items,
       tracks = const [],
       albums = const [],
       playlists = const [],
       categories = const [];

  const HomeShelf.playlists({
    required this.id,
    required this.title,
    required List<Playlist> items,
    this.subtitle,
    this.error,
  }) : kind = ShelfKind.playlists,
       playlists = items,
       tracks = const [],
       albums = const [],
       artists = const [],
       categories = const [];

  const HomeShelf.categories({
    required this.id,
    required this.title,
    required List<Category> items,
    this.subtitle,
    this.error,
  }) : kind = ShelfKind.categories,
       categories = items,
       tracks = const [],
       albums = const [],
       artists = const [],
       playlists = const [];

  int get itemCount {
    switch (kind) {
      case ShelfKind.tracks:
        return tracks.length;
      case ShelfKind.albums:
        return albums.length;
      case ShelfKind.artists:
        return artists.length;
      case ShelfKind.playlists:
        return playlists.length;
      case ShelfKind.categories:
        return categories.length;
    }
  }

  bool get isEmpty => itemCount == 0;

  /// A shelf is rendered only when it has content. An empty shelf with an
  /// error is dropped silently rather than showing the user a wall of
  /// apologies for endpoints they never asked about.
  bool get shouldRender => itemCount > 0;

  @override
  List<Object?> get props => [id, title, kind, tracks, albums, artists, playlists, categories];
}

/// The whole Home payload.
class HomeFeed extends Equatable {
  const HomeFeed({
    required this.shelves,
    this.isStale = false,
    this.generatedAt,
  });

  final List<HomeShelf> shelves;

  /// True when this came from cache because the network was unavailable.
  /// Drives the "Showing offline data" banner.
  final bool isStale;

  final DateTime? generatedAt;

  static const HomeFeed empty = HomeFeed(shelves: []);

  List<HomeShelf> get visibleShelves =>
      shelves.where((s) => s.shouldRender).toList(growable: false);

  bool get isEmpty => visibleShelves.isEmpty;

  HomeFeed copyWith({List<HomeShelf>? shelves, bool? isStale}) => HomeFeed(
    shelves: shelves ?? this.shelves,
    isStale: isStale ?? this.isStale,
    generatedAt: generatedAt,
  );

  @override
  List<Object?> get props => [shelves, isStale, generatedAt];
}

/// Stable IDs for the shelves, so the UI can special-case one (e.g. render
/// "Recently played" as a compact grid) without matching on a display string.
abstract final class ShelfIds {
  static const String recentlyPlayed = 'recently_played';
  static const String madeForYou = 'made_for_you';
  static const String trending = 'trending';
  static const String recommended = 'recommended';
  static const String popularArtists = 'popular_artists';
  static const String savedAlbums = 'saved_albums';
  static const String likedSongs = 'liked_songs';
  static const String followedArtists = 'followed_artists';
  static const String moods = 'moods';

  /// Shelves that no longer exist, kept only so a cache written by an older
  /// build is discarded rather than rendered.
  ///
  /// `new_releases` and `popular_albums` were built on
  /// `/browse/new-releases`, which Spotify removed from Development Mode apps
  /// in February 2026. A user upgrading from a previous build has them sitting
  /// in the on-disk Home cache; without this they would render as permanently
  /// empty sections that never refill.
  static const Set<String> retired = <String>{
    'new_releases',
    'popular_albums',
    'featured_playlists',
    'categories',
  };
}
