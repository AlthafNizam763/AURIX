import 'package:equatable/equatable.dart';

import 'album.dart';
import 'artist.dart';
import 'json_utils.dart';
import 'media_source.dart';
import 'song_key.dart';
import 'spotify_image.dart';
import 'track.dart';
import 'track_key.dart';

/// A song in the AURIX catalogue.
///
/// ## What this is, next to [Track]
///
/// [Track] is the app's *runtime* type: it is what every list row, the queue,
/// the player and the mini player already speak, and rewriting the app around a
/// new type would have touched every screen for no user-visible gain.
///
/// [Song] is the *catalogue document* — one row of `catalog/songs/{songId}`,
/// with the normalised shape the import path produces and the search index
/// reads. The two convert freely ([fromTrack], [toTrack]), and the conversion
/// is where the source-specific detail is folded away.
///
/// So the rule the rest of AURIX follows is unchanged and is worth restating:
/// **nothing outside this file and the import providers cares whether a song
/// came from Spotify or YouTube.** A row in a playlist is a [Track]; where it
/// came from is a field on it, not a branch in the code that renders it.
///
/// ## Identity
///
/// [id] is derived from the normalised title and primary artist — see
/// [SongKey]. It is deliberately *not* the provider's id: importing the same
/// song from Spotify and from YouTube must converge on one document, and a
/// provider-keyed id cannot. Both provider ids are carried alongside instead,
/// so whichever playback provider is available can address the song.
///
/// ## What is stored, and what is never stored
///
/// Metadata and references. Titles, artists, an album name, a duration, a URL
/// to artwork the source already hosts, and the ids needed to ask an authorised
/// player for the audio. **No audio.** AURIX does not download, cache, re-encode
/// or upload Spotify or YouTube audio, and [artworkUrl] is a link to the
/// source's CDN rather than a copy of the image.
class Song extends Equatable {
  const Song({
    required this.id,
    required this.title,
    required this.artists,
    this.album = '',
    this.durationMs = 0,
    this.artworkUrl,
    this.source = MediaSource.aurix,
    this.sourceId,
    this.externalUrl,
    this.spotifyId,
    this.youtubeVideoId,
    this.isExplicit = false,
    this.previewUrl,
    this.searchTokens = const <String>[],
    this.createdAt,
    this.updatedAt,
  });

  /// The catalogue document id. Deterministic — see [SongKey].
  final String id;

  final String title;

  /// Every credited artist, in the order the source listed them.
  ///
  /// A list rather than the single display string [Track] stores, because the
  /// catalogue is the canonical copy and flattening is lossy. `artistNames`
  /// renders it back to the display form the UI wants.
  final List<String> artists;

  final String album;
  final int durationMs;

  /// A URL at the source's CDN. Referenced, never copied.
  final String? artworkUrl;

  /// Which service this document's metadata was first imported from.
  final MediaSource source;

  /// The id at [source] — the Spotify track id or the YouTube video id that
  /// created this row.
  final String? sourceId;

  /// A link back to the song on the service it came from.
  final String? externalUrl;

  /// Spotify's track id, when one is known.
  ///
  /// Held separately from [sourceId] because they answer different questions:
  /// `sourceId` is provenance, this is *capability*. A song first imported from
  /// YouTube and later matched to a Spotify entry carries both, and either
  /// playback provider can then address it.
  final String? spotifyId;

  /// YouTube's video id, when one is known. The counterpart to [spotifyId].
  final String? youtubeVideoId;

  final bool isExplicit;

  /// A short preview the source publishes for open use, when it does.
  ///
  /// The one audio URL AURIX is permitted to stream itself. Null for most
  /// songs, and never synthesised.
  final String? previewUrl;

  /// The prefix tokens that make this row findable. See [SearchTokens].
  ///
  /// Stored on the document rather than computed at query time, because the
  /// whole point is that a search is an index lookup and not a scan.
  final List<String> searchTokens;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// The display credit — "The Weeknd, Daft Punk".
  String get artistNames => artists.where((a) => a.isNotEmpty).join(', ');

  String get primaryArtist => artists.isEmpty ? '' : artists.first;

  Duration get duration => Duration(milliseconds: durationMs);

  // -------------------------------------------------------------------------
  // Conversion
  // -------------------------------------------------------------------------

  /// Builds a catalogue song from an AURIX runtime track.
  ///
  /// The id is **recomputed** rather than taken from the track. A track's own
  /// `documentId` is provider-qualified (`spotify_abc123`), which is the right
  /// key for a row inside one user's playlist and the wrong key for a shared
  /// catalogue — two services' ids for one song would make two rows.
  factory Song.fromTrack(Track track) {
    final artists = track.artists
        .map((artist) => artist.name)
        .where((name) => name.isNotEmpty)
        .toList(growable: false);

    final credit = artists.isEmpty ? track.artistNames : artists.join(', ');

    return Song(
      id: SongKey.of(title: track.name, artist: credit),
      title: track.name,
      artists: artists.isEmpty ? <String>[track.artistNames] : artists,
      album: track.album?.name ?? '',
      durationMs: track.durationMs,
      artworkUrl: track.artworkUrl,
      source: track.source,
      sourceId: track.sourceId,
      externalUrl: track.spotifyUrl,
      spotifyId: track.spotifyId,
      youtubeVideoId: track.youtubeVideoId,
      isExplicit: track.isExplicit,
      previewUrl: track.previewUrl,
      searchTokens: SearchTokens.forSong(
        title: track.name,
        artist: credit,
        album: track.album?.name ?? '',
      ),
    );
  }

  /// Builds the runtime track the rest of AURIX renders and plays.
  ///
  /// The nested [Artist] and [Album] objects the UI expects are synthesised
  /// here, which is what lets a catalogue row drop into any existing list,
  /// queue or player with no call site changed.
  ///
  /// ## Why the track's id is not the catalogue id
  ///
  /// They key different things. The catalogue id ([SongKey]) identifies a song
  /// across services; a track's id is its document id *inside the user's
  /// library* ([TrackKey]), which is provider-qualified — `spotify_0VjIjW4G`.
  ///
  /// A track built here with `sng_…` in its `id` would still like, queue and
  /// play correctly, because every one of those paths goes through
  /// `Track.documentId` rather than `Track.id`. But the two fields would
  /// disagree on the same object, and anything that compared tracks by `id` —
  /// queue de-duplication, a list key, the tie-break in
  /// `FirestorePlaylistService._tracksFrom` — would decide that the search
  /// result and the playlist row are different songs.
  ///
  /// So the id is computed the way the rest of the app computes it, and the
  /// invariant `track.id == track.documentId` holds for every track that comes
  /// out of the catalogue.
  Track toTrack() {
    final track = _toTrackWithId(id);
    return _toTrackWithId(TrackKey.of(track));
  }

  Track _toTrackWithId(String trackId) => Track(
    id: trackId,
    name: title,
    artists: artists.isEmpty
        ? const <Artist>[Artist(id: '', name: 'Unknown artist')]
        : artists.map((name) => Artist(id: '', name: name)).toList(),
    durationMs: durationMs,
    album: album.isEmpty && artworkUrl == null
        ? null
        : Album(
            id: '',
            name: album,
            artists: const <Artist>[],
            images: <SpotifyImage>[
              if (artworkUrl != null && artworkUrl!.isNotEmpty)
                SpotifyImage(url: artworkUrl!),
            ],
          ),
    isExplicit: isExplicit,
    previewUrl: previewUrl,
    spotifyUrl: externalUrl,
    source: source,
    sourceId: sourceId,
    spotifyId: spotifyId,
    youtubeVideoId: youtubeVideoId,
    addedAt: createdAt,
  );

  // -------------------------------------------------------------------------
  // Firestore
  // -------------------------------------------------------------------------

  factory Song.fromFirestore(String id, Map<String, dynamic> data) {
    final rawArtists = data['artists'];
    final artists = rawArtists is List
        ? rawArtists.whereType<String>().toList(growable: false)
        : <String>[Json.str(data, 'artist', fallback: 'Unknown artist')];

    final rawTokens = data['searchTokens'];

    return Song(
      id: id,
      title: Json.str(data, 'title', fallback: 'Unknown track'),
      artists: artists.isEmpty ? const <String>['Unknown artist'] : artists,
      album: Json.str(data, 'album'),
      durationMs: Json.intVal(data, 'duration'),
      artworkUrl: Json.strOrNull(data, 'artworkUrl'),
      source: MediaSource.parse(data['source']),
      sourceId: Json.strOrNull(data, 'sourceId'),
      externalUrl: Json.strOrNull(data, 'externalUrl'),
      spotifyId: Json.strOrNull(data, 'spotifyId'),
      youtubeVideoId: Json.strOrNull(data, 'youtubeVideoId'),
      isExplicit: Json.boolVal(data, 'explicit'),
      previewUrl: Json.strOrNull(data, 'previewUrl'),
      searchTokens: rawTokens is List
          ? rawTokens.whereType<String>().toList(growable: false)
          : const <String>[],
      createdAt: Json.timestamp(data, 'createdAt'),
      updatedAt: Json.timestamp(data, 'updatedAt'),
    );
  }

  /// The document body for `catalog/songs/{id}`.
  ///
  /// `createdAt` and `updatedAt` are absent by design: both are server
  /// timestamps written by `FirestoreCatalogService`, because a client clock is
  /// not something a shared collection can be ordered by.
  ///
  /// The field names here are the ones `firestore.rules` validates. Changing
  /// one is a rules change as well as a code change.
  Map<String, dynamic> toFirestore() => <String, dynamic>{
    'id': id,
    'title': title,
    'artists': artists,
    'album': album,
    'duration': durationMs,
    'artworkUrl': artworkUrl ?? '',
    'source': source.wireValue,
    'sourceId': sourceId ?? '',
    'externalUrl': externalUrl ?? '',
    'explicit': isExplicit,
    'searchTokens': searchTokens,
    if (spotifyId != null && spotifyId!.isNotEmpty) 'spotifyId': spotifyId,
    if (youtubeVideoId != null && youtubeVideoId!.isNotEmpty)
      'youtubeVideoId': youtubeVideoId,
    if (previewUrl != null && previewUrl!.isNotEmpty) 'previewUrl': previewUrl,
  };

  /// The subset of fields a *second* import of the same song may update.
  ///
  /// A re-import must be able to improve a row — a better artwork URL, a
  /// duration the first source did not have, the provider id from the other
  /// service — without erasing what is already there. So this merges rather
  /// than replaces: a field is written only when this copy actually has a value
  /// for it, and never when that would overwrite something with nothing.
  ///
  /// It also never rewrites `source`, `createdAt` or `id`. Those record how the
  /// row first came to exist, and a later import does not change that history.
  Map<String, dynamic> toFirestoreMerge(Song existing) => <String, dynamic>{
    // Longer titles usually mean the other service kept detail this one
    // dropped, but a title is the identity — replacing it would make the
    // document disagree with its own key. Left alone.
    if (album.isNotEmpty && existing.album.isEmpty) 'album': album,
    if (durationMs > 0 && existing.durationMs == 0) 'duration': durationMs,
    if ((artworkUrl?.isNotEmpty ?? false) &&
        (existing.artworkUrl?.isEmpty ?? true))
      'artworkUrl': artworkUrl,
    if ((externalUrl?.isNotEmpty ?? false) &&
        (existing.externalUrl?.isEmpty ?? true))
      'externalUrl': externalUrl,
    // The capability ids are the point of merging at all: this is how a song
    // known to Spotify gains its YouTube id, and becomes playable by either.
    if ((spotifyId?.isNotEmpty ?? false) && existing.spotifyId == null)
      'spotifyId': spotifyId,
    if ((youtubeVideoId?.isNotEmpty ?? false) && existing.youtubeVideoId == null)
      'youtubeVideoId': youtubeVideoId,
    if ((previewUrl?.isNotEmpty ?? false) && existing.previewUrl == null)
      'previewUrl': previewUrl,
    // Re-tokenised whenever anything searchable improved, so a row that gained
    // an album name becomes findable by it.
    if (album.isNotEmpty && existing.album.isEmpty)
      'searchTokens': SearchTokens.forSong(
        title: title,
        artist: artistNames,
        album: album,
      ),
  };

  Song copyWith({
    String? album,
    int? durationMs,
    String? artworkUrl,
    String? externalUrl,
    String? spotifyId,
    String? youtubeVideoId,
    String? previewUrl,
    DateTime? createdAt,
  }) => Song(
    id: id,
    title: title,
    artists: artists,
    album: album ?? this.album,
    durationMs: durationMs ?? this.durationMs,
    artworkUrl: artworkUrl ?? this.artworkUrl,
    source: source,
    sourceId: sourceId,
    externalUrl: externalUrl ?? this.externalUrl,
    spotifyId: spotifyId ?? this.spotifyId,
    youtubeVideoId: youtubeVideoId ?? this.youtubeVideoId,
    isExplicit: isExplicit,
    previewUrl: previewUrl ?? this.previewUrl,
    searchTokens: searchTokens,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt,
  );

  @override
  List<Object?> get props => [
    id,
    title,
    artists,
    album,
    durationMs,
    source,
    sourceId,
    spotifyId,
    youtubeVideoId,
  ];
}
