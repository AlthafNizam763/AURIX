import 'package:equatable/equatable.dart';

import 'json_utils.dart';
import 'spotify_image.dart';

/// An artist.
///
/// Spotify returns two shapes for artists: a *simplified* object (id, name,
/// uri — what appears inside a track) and a *full* object (adds images,
/// genres, popularity, followers). Both parse into this one class;
/// [isSimplified] tells a screen whether it needs to fetch the full object
/// before rendering a header.
class Artist extends Equatable {
  const Artist({
    required this.id,
    required this.name,
    this.images = const [],
    this.genres = const [],
    this.popularity,
    this.followers,
    this.spotifyUrl,
    this.uri,
  });

  final String id;
  final String name;
  final List<SpotifyImage> images;
  final List<String> genres;

  /// 0–100. Null on simplified objects.
  final int? popularity;

  /// Null on simplified objects.
  final int? followers;

  final String? spotifyUrl;
  final String? uri;

  factory Artist.fromJson(Map<String, dynamic> json) {
    final followers = Json.obj(json, 'followers');
    return Artist(
      id: Json.str(json, 'id'),
      name: Json.str(json, 'name', fallback: 'Unknown artist'),
      images: Json.list(json, 'images', SpotifyImage.fromJson),
      genres: Json.stringList(json, 'genres'),
      popularity: Json.intOrNull(json, 'popularity'),
      followers: followers == null ? null : Json.intOrNull(followers, 'total'),
      spotifyUrl: Json.spotifyUrl(json),
      uri: Json.strOrNull(json, 'uri'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'images': images.map((i) => i.toJson()).toList(),
    'genres': genres,
    if (popularity != null) 'popularity': popularity,
    if (followers != null) 'followers': <String, dynamic>{'total': followers},
    if (spotifyUrl != null) 'external_urls': <String, dynamic>{'spotify': spotifyUrl},
    if (uri != null) 'uri': uri,
  };

  /// True when this came from a nested reference and lacks artwork/genres.
  bool get isSimplified => images.isEmpty && popularity == null;

  String? get imageUrl => images.largestUrl;
  String? get avatarUrl => images.bestFor(300);
  String get spotifyUri => uri ?? 'spotify:artist:$id';

  /// Spotify has no "verified" flag in the Web API. Popularity is the closest
  /// public signal, and the UI shows a distinct "Popular artist" marker rather
  /// than claiming a verification Spotify never asserted.
  bool get isHighProfile => (popularity ?? 0) >= 70;

  Artist copyWith({
    List<SpotifyImage>? images,
    List<String>? genres,
    int? popularity,
    int? followers,
  }) => Artist(
    id: id,
    name: name,
    images: images ?? this.images,
    genres: genres ?? this.genres,
    popularity: popularity ?? this.popularity,
    followers: followers ?? this.followers,
    spotifyUrl: spotifyUrl,
    uri: uri,
  );

  @override
  List<Object?> get props => [id, name, images, genres, popularity, followers];
}
