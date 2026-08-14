import 'package:equatable/equatable.dart';

import 'artist.dart';
import 'json_utils.dart';
import 'paging.dart';
import 'spotify_image.dart';
import 'track.dart';

enum AlbumType {
  album,
  single,
  compilation,
  appearsOn;

  static AlbumType parse(String? raw) {
    switch (raw?.toLowerCase()) {
      case 'single':
        return AlbumType.single;
      case 'compilation':
        return AlbumType.compilation;
      case 'appears_on':
        return AlbumType.appearsOn;
      default:
        return AlbumType.album;
    }
  }

  String get label {
    switch (this) {
      case AlbumType.album:
        return 'Album';
      case AlbumType.single:
        return 'Single';
      case AlbumType.compilation:
        return 'Compilation';
      case AlbumType.appearsOn:
        return 'Appears on';
    }
  }
}

/// An album, EP or single.
///
/// As with [Artist], simplified and full objects both parse here. [tracks] is
/// only populated by `GET /albums/{id}`; on a simplified object it is null,
/// which is the signal that the album screen must fetch the full record.
class Album extends Equatable {
  const Album({
    required this.id,
    required this.name,
    required this.artists,
    this.images = const [],
    this.albumType = AlbumType.album,
    this.releaseDate = '',
    this.releaseDatePrecision = 'day',
    this.totalTracks = 0,
    this.tracks,
    this.popularity,
    this.label,
    this.genres = const [],
    this.copyrights = const [],
    this.spotifyUrl,
    this.uri,
    this.isPlayable,
  });

  final String id;
  final String name;
  final List<Artist> artists;
  final List<SpotifyImage> images;
  final AlbumType albumType;

  /// Raw Spotify value: `1994`, `1994-03`, or `1994-03-21`.
  final String releaseDate;

  /// `year` | `month` | `day` — how much of [releaseDate] is meaningful.
  final String releaseDatePrecision;

  final int totalTracks;

  /// Populated only on the full object.
  final Paging<Track>? tracks;

  final int? popularity;
  final String? label;
  final List<String> genres;
  final List<String> copyrights;
  final String? spotifyUrl;
  final String? uri;
  final bool? isPlayable;

  factory Album.fromJson(Map<String, dynamic> json) {
    final tracksJson = Json.obj(json, 'tracks');
    return Album(
      id: Json.str(json, 'id'),
      name: Json.str(json, 'name', fallback: 'Unknown album'),
      artists: Json.list(json, 'artists', Artist.fromJson),
      images: Json.list(json, 'images', SpotifyImage.fromJson),
      // `album_group` is what distinguishes "appears_on" on the artist
      // discography endpoint; `album_type` never carries it.
      albumType: AlbumType.parse(
        Json.strOrNull(json, 'album_group') ?? Json.strOrNull(json, 'album_type'),
      ),
      releaseDate: Json.str(json, 'release_date'),
      releaseDatePrecision: Json.str(json, 'release_date_precision', fallback: 'day'),
      totalTracks: Json.intVal(json, 'total_tracks'),
      tracks: tracksJson == null
          ? null
          : Paging<Track>.fromJson(tracksJson, Track.fromJson),
      popularity: Json.intOrNull(json, 'popularity'),
      label: Json.strOrNull(json, 'label'),
      genres: Json.stringList(json, 'genres'),
      copyrights: Json.listFrom<String>(
        json['copyrights'],
        (entry) => Json.str(entry, 'text'),
      ),
      spotifyUrl: Json.spotifyUrl(json),
      uri: Json.strOrNull(json, 'uri'),
      isPlayable: json['is_playable'] as bool?,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'artists': artists.map((a) => a.toJson()).toList(),
    'images': images.map((i) => i.toJson()).toList(),
    'album_type': albumType.name,
    'release_date': releaseDate,
    'release_date_precision': releaseDatePrecision,
    'total_tracks': totalTracks,
    if (tracks != null) 'tracks': tracks!.toJson((t) => t.toJson()),
    if (popularity != null) 'popularity': popularity,
    if (label != null) 'label': label,
    'genres': genres,
    'copyrights': copyrights.map((c) => <String, dynamic>{'text': c}).toList(),
    if (spotifyUrl != null) 'external_urls': <String, dynamic>{'spotify': spotifyUrl},
    if (uri != null) 'uri': uri,
  };

  bool get isSimplified => tracks == null;

  String? get imageUrl => images.largestUrl;
  String? get cardImageUrl => images.cardUrl;
  String? get thumbnailUrl => images.smallestUrl;

  String get artistNames => artists.map((a) => a.name).join(', ');
  Artist? get primaryArtist => artists.isEmpty ? null : artists.first;
  String get releaseYear => releaseDate.split('-').first;
  String get spotifyUri => uri ?? 'spotify:album:$id';

  /// Sum of the loaded track durations. Only meaningful once the full album
  /// has been fetched *and* its first track page covers every track.
  Duration? get totalDuration {
    final loaded = tracks?.items;
    if (loaded == null || loaded.length < totalTracks) return null;
    return loaded.fold<Duration>(
      Duration.zero,
      (sum, track) => sum + track.duration,
    );
  }

  Album copyWith({Paging<Track>? tracks, List<SpotifyImage>? images}) => Album(
    id: id,
    name: name,
    artists: artists,
    images: images ?? this.images,
    albumType: albumType,
    releaseDate: releaseDate,
    releaseDatePrecision: releaseDatePrecision,
    totalTracks: totalTracks,
    tracks: tracks ?? this.tracks,
    popularity: popularity,
    label: label,
    genres: genres,
    copyrights: copyrights,
    spotifyUrl: spotifyUrl,
    uri: uri,
    isPlayable: isPlayable,
  );

  @override
  List<Object?> get props => [id, name, artists, images, releaseDate, totalTracks, tracks];
}
