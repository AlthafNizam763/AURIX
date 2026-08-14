import 'package:equatable/equatable.dart';

import 'album.dart';
import 'artist.dart';
import 'json_utils.dart';
import 'spotify_image.dart';

/// A track.
///
/// [album] is null when the track came from `GET /albums/{id}/tracks`, because
/// Spotify omits the album on tracks nested inside their own album. Screens
/// that need artwork in that context pass the parent album down explicitly
/// rather than firing another request per row — see `resolveAlbum`.
class Track extends Equatable {
  const Track({
    required this.id,
    required this.name,
    required this.artists,
    required this.durationMs,
    this.album,
    this.trackNumber = 0,
    this.discNumber = 1,
    this.isExplicit = false,
    this.popularity,
    this.previewUrl,
    this.isLocal = false,
    this.isPlayable,
    this.spotifyUrl,
    this.uri,
  });

  final String id;
  final String name;
  final List<Artist> artists;
  final int durationMs;
  final Album? album;
  final int trackNumber;
  final int discNumber;
  final bool isExplicit;
  final int? popularity;

  /// 30-second MP3 preview.
  ///
  /// Spotify stopped populating this for applications created on or after
  /// 27 November 2024, so it is null for most new developer apps. AURIX
  /// treats it as an optional capability: present means real local playback,
  /// absent means the track can still be played through Spotify Connect.
  /// It is never faked, and the audio is streamed, never stored.
  final String? previewUrl;

  /// A file the user added from their own device. Has no Spotify ID and can
  /// never be played or looked up through the Web API.
  final bool isLocal;

  final bool? isPlayable;
  final String? spotifyUrl;
  final String? uri;

  factory Track.fromJson(Map<String, dynamic> json) {
    final albumJson = Json.obj(json, 'album');
    return Track(
      id: Json.str(json, 'id'),
      name: Json.str(json, 'name', fallback: 'Unknown track'),
      artists: Json.list(json, 'artists', Artist.fromJson),
      durationMs: Json.intVal(json, 'duration_ms'),
      album: albumJson == null ? null : Album.fromJson(albumJson),
      trackNumber: Json.intVal(json, 'track_number'),
      discNumber: Json.intVal(json, 'disc_number', fallback: 1),
      isExplicit: Json.boolVal(json, 'explicit'),
      popularity: Json.intOrNull(json, 'popularity'),
      previewUrl: Json.strOrNull(json, 'preview_url'),
      isLocal: Json.boolVal(json, 'is_local'),
      isPlayable: json['is_playable'] as bool?,
      spotifyUrl: Json.spotifyUrl(json),
      uri: Json.strOrNull(json, 'uri'),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'name': name,
    'artists': artists.map((a) => a.toJson()).toList(),
    'duration_ms': durationMs,
    if (album != null) 'album': album!.toJson(),
    'track_number': trackNumber,
    'disc_number': discNumber,
    'explicit': isExplicit,
    if (popularity != null) 'popularity': popularity,
    if (previewUrl != null) 'preview_url': previewUrl,
    'is_local': isLocal,
    if (spotifyUrl != null) 'external_urls': <String, dynamic>{'spotify': spotifyUrl},
    if (uri != null) 'uri': uri,
  };

  Duration get duration => Duration(milliseconds: durationMs);
  String get artistNames => artists.map((a) => a.name).join(', ');
  Artist? get primaryArtist => artists.isEmpty ? null : artists.first;
  String get spotifyUri => uri ?? 'spotify:track:$id';

  List<SpotifyImage> get images => album?.images ?? const [];
  String? get artworkUrl => images.largestUrl;
  String? get cardArtworkUrl => images.cardUrl;
  String? get thumbnailUrl => images.smallestUrl;

  /// True when a 30-second preview stream is available for local playback.
  bool get hasPreview => (previewUrl?.isNotEmpty ?? false) && !isLocal;

  /// True when the track can be addressed by Spotify Connect. Local files and
  /// region-blocked tracks cannot.
  bool get isConnectPlayable => !isLocal && id.isNotEmpty && (isPlayable ?? true);

  /// Fills in a missing [album] from a known parent, so tracks fetched via
  /// `/albums/{id}/tracks` still render artwork without an extra request.
  Track withAlbum(Album parent) =>
      album != null ? this : copyWith(album: parent);

  Track copyWith({Album? album, bool? isPlayable}) => Track(
    id: id,
    name: name,
    artists: artists,
    durationMs: durationMs,
    album: album ?? this.album,
    trackNumber: trackNumber,
    discNumber: discNumber,
    isExplicit: isExplicit,
    popularity: popularity,
    previewUrl: previewUrl,
    isLocal: isLocal,
    isPlayable: isPlayable ?? this.isPlayable,
    spotifyUrl: spotifyUrl,
    uri: uri,
  );

  @override
  List<Object?> get props => [id, name, artists, durationMs, album, trackNumber, uri];
}
