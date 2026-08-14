import 'package:equatable/equatable.dart';

import 'album.dart';
import 'artist.dart';
import 'json_utils.dart';
import 'media_source.dart';
import 'spotify_image.dart';
import 'track_key.dart';

/// A track.
///
/// ## AURIX's track, not Spotify's
///
/// This model started as a parse of Spotify's track object and is now AURIX's
/// own: the canonical copy of a track lives in Firestore, and [fromFirestore] /
/// [toFirestore] are the pair that round-trips it. [fromJson] is still here
/// because Spotify's shape has to be read *somewhere* — but that somewhere is
/// now only the import provider and the retained playback services, not the app.
///
/// [source] and [sourceId] record where a track came from, and the per-provider
/// id fields ([spotifyId], [youtubeVideoId]) are what let a playback provider
/// decide whether it can play this track at all. They are null for a track
/// created in AURIX, which is the normal case and not an error.
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
    this.source = MediaSource.aurix,
    this.sourceId,
    this.spotifyId,
    this.youtubeVideoId,
    this.addedAt,
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

  /// Where this track's metadata originated. See [MediaSource].
  final MediaSource source;

  /// The id this track had at [source], or null when it was created in AURIX.
  final String? sourceId;

  /// Spotify's track id, when one is known.
  ///
  /// Separate from [sourceId] rather than derived from it, because the two
  /// answer different questions. `sourceId` is provenance — "this row came from
  /// there". `spotifyId` is capability — "the Spotify playback provider can
  /// play this". A track imported from YouTube and later matched to a Spotify
  /// catalogue entry has both, pointing at different services.
  final String? spotifyId;

  /// YouTube video id, when one is known. The YouTube playback provider's
  /// equivalent of [spotifyId].
  final String? youtubeVideoId;

  /// When this track entered the user's AURIX library. Null off Firestore.
  final DateTime? addedAt;

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
      // A track parsed from Spotify's own payload is by definition a Spotify
      // track. Recording it here means an imported row carries its provenance
      // from the moment it is read, rather than having it attached later by
      // whichever code path happened to remember.
      source: MediaSource.spotify,
      sourceId: Json.strOrNull(json, 'id'),
      spotifyId: Json.strOrNull(json, 'id'),
    );
  }

  // -------------------------------------------------------------------------
  // Firestore — the canonical AURIX representation
  // -------------------------------------------------------------------------

  /// Reads a track document from `/users/{uid}/likedTracks` or
  /// `/users/{uid}/playlists/{id}/tracks`.
  ///
  /// The stored shape is flat — `artist` and `album` are strings, and there is
  /// one `artworkUrl` rather than a rendition list — because that is what a
  /// document should hold: the fields the app actually renders, denormalised so
  /// a list of fifty rows is one read and not fifty joins.
  ///
  /// The nested [Artist] and [Album] objects the UI expects are *synthesised*
  /// from those strings here. That is the whole reason the existing screens did
  /// not have to change: a Firestore track and a Spotify track present exactly
  /// the same surface, so `track.artistNames`, `track.album?.name` and
  /// `track.artworkUrl` keep working with no call site touched.
  factory Track.fromFirestore(String id, Map<String, dynamic> data) {
    final artworkUrl = Json.strOrNull(data, 'artworkUrl');
    final albumName = Json.strOrNull(data, 'album');
    final artistName = Json.str(data, 'artist', fallback: 'Unknown artist');

    return Track(
      id: id,
      name: Json.str(data, 'title', fallback: 'Unknown track'),
      // A single synthetic artist rather than a parsed list. Firestore stores
      // the display string ("Daft Punk, Pharrell Williams") because that is
      // what every row renders; splitting it back into artist objects would
      // invent ids that address nothing.
      artists: <Artist>[Artist(id: '', name: artistName)],
      durationMs: Json.intVal(data, 'durationMs'),
      album: albumName == null && artworkUrl == null
          ? null
          : Album(
              id: '',
              name: albumName ?? '',
              artists: const <Artist>[],
              images: <SpotifyImage>[
                if (artworkUrl != null && artworkUrl.isNotEmpty)
                  SpotifyImage(url: artworkUrl),
              ],
            ),
      isExplicit: Json.boolVal(data, 'explicit'),
      previewUrl: Json.strOrNull(data, 'previewUrl'),
      source: MediaSource.parse(data['source']),
      sourceId: Json.strOrNull(data, 'sourceId'),
      spotifyId: Json.strOrNull(data, 'spotifyId'),
      youtubeVideoId: Json.strOrNull(data, 'youtubeVideoId'),
      addedAt: Json.timestamp(data, 'createdAt'),
    );
  }

  /// The document body for this track.
  ///
  /// `createdAt` is deliberately **not** written here. It is a server timestamp
  /// and belongs to the write path — see `FirestoreLibraryService`, which adds
  /// `FieldValue.serverTimestamp()` on create and leaves it alone on update.
  /// Emitting a client clock value here would let a device with a wrong clock
  /// reorder someone's entire library.
  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'title': name,
    'artist': artistNames,
    'album': album?.name ?? '',
    'durationMs': durationMs,
    'artworkUrl': artworkUrl ?? '',
    'explicit': isExplicit,
    'source': source.wireValue,
    'sourceId': sourceId,
    'spotifyId': spotifyId,
    'youtubeVideoId': youtubeVideoId,
    // Kept because it is the one audio URL AURIX is licensed to stream itself.
    // Null for almost every track — see [previewUrl].
    if (previewUrl != null && previewUrl!.isNotEmpty) 'previewUrl': previewUrl,
  };

  /// The Firestore document id for this track.
  ///
  /// Deterministic, and that is the point: liking the same song twice must
  /// address the same document, and re-importing a Spotify playlist must update
  /// its rows rather than duplicating them. A random id would make both of those
  /// impossible to detect after the fact.
  ///
  /// Provider-qualified so two services that happen to use the same id string
  /// cannot collide.
  String get documentId => TrackKey.of(this);

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
    // AURIX's own fields, camelCase like the Firestore document, so a track
    // that round-trips through the local metadata cache keeps its provenance.
    // Without these, a cached track came back as a source-less AURIX row and
    // the playback layer could no longer tell that Spotify could play it.
    'source': source.wireValue,
    if (sourceId != null) 'sourceId': sourceId,
    if (spotifyId != null) 'spotifyId': spotifyId,
    if (youtubeVideoId != null) 'youtubeVideoId': youtubeVideoId,
  };

  Duration get duration => Duration(milliseconds: durationMs);
  String get artistNames => artists.map((a) => a.name).join(', ');
  Artist? get primaryArtist => artists.isEmpty ? null : artists.first;

  /// The Spotify URI for this track, or null when there is no Spotify track
  /// behind it.
  ///
  /// Nullable, unlike the old `spotifyUri` getter it replaces. That getter
  /// synthesised `spotify:track:$id` from whatever id the track happened to
  /// carry, which was correct while every track in AURIX came from Spotify and
  /// is a fabrication now: an AURIX-native track's id is `aurix_slug`, and
  /// `spotify:track:aurix_slug` addresses nothing. Callers must handle null —
  /// that is the compile-time reminder that not every track is playable by
  /// Spotify.
  String? get spotifyUri {
    if (uri != null && uri!.isNotEmpty) return uri;
    final id = spotifyId ?? (source == MediaSource.spotify ? sourceId : null);
    if (id == null || id.isEmpty) return null;
    return 'spotify:track:$id';
  }

  /// True when a Spotify playback provider could address this track.
  bool get hasSpotifyId => spotifyUri != null;

  List<SpotifyImage> get images => album?.images ?? const [];
  String? get artworkUrl => images.largestUrl;
  String? get cardArtworkUrl => images.cardUrl;
  String? get thumbnailUrl => images.smallestUrl;

  /// True when a 30-second preview stream is available for local playback.
  bool get hasPreview => (previewUrl?.isNotEmpty ?? false) && !isLocal;

  /// True when the track can be addressed by Spotify Connect.
  ///
  /// Local files and region-blocked tracks cannot — and neither can a track
  /// AURIX owns that was never matched to a Spotify catalogue entry, which is
  /// the case this gained when Firestore became the library. Returning true for
  /// one of those would send `spotify:track:aurix_some-slug` to a Connect
  /// device, which fails as an opaque 404 several layers away from the cause.
  bool get isConnectPlayable => !isLocal && hasSpotifyId && (isPlayable ?? true);

  /// Fills in a missing [album] from a known parent, so tracks fetched via
  /// `/albums/{id}/tracks` still render artwork without an extra request.
  Track withAlbum(Album parent) =>
      album != null ? this : copyWith(album: parent);

  Track copyWith({
    String? id,
    Album? album,
    bool? isPlayable,
    MediaSource? source,
    String? sourceId,
    String? spotifyId,
    String? youtubeVideoId,
    DateTime? addedAt,
  }) => Track(
    id: id ?? this.id,
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
    source: source ?? this.source,
    sourceId: sourceId ?? this.sourceId,
    spotifyId: spotifyId ?? this.spotifyId,
    youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
    addedAt: addedAt ?? this.addedAt,
  );

  @override
  List<Object?> get props => [
    id,
    name,
    artists,
    durationMs,
    album,
    trackNumber,
    uri,
    source,
    sourceId,
    spotifyId,
    youtubeVideoId,
  ];
}
