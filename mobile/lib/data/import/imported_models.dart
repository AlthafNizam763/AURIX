import '../models/album.dart';
import '../models/artist.dart';
import '../models/media_source.dart';
import '../models/playlist.dart';
import '../models/spotify_image.dart';
import '../models/track.dart';
import '../models/track_key.dart';

/// A playlist as some other service describes it.
///
/// ## Why this exists rather than reusing [Playlist]
///
/// [Playlist] is an AURIX record: it has a Firestore document id, a
/// `trackCount` maintained by the write path, and server timestamps. None of
/// those exist yet at import time, and inventing them in the provider would put
/// knowledge of AURIX's storage into every provider that is ever written.
///
/// So a provider produces this, which is a description and nothing more, and
/// [MusicImportService] is the single place that turns a description into an
/// AURIX record. A new provider therefore never touches Firestore, never
/// computes a document id, and cannot get the storage layout wrong — it has no
/// access to it.
class ImportedPlaylist {
  const ImportedPlaylist({
    required this.id,
    required this.name,
    this.description = '',
    this.coverUrl,
    this.trackCount = 0,
    this.ownerName,
  });

  /// The playlist's id **at the source**, not in AURIX.
  ///
  /// Stored on the AURIX playlist as `sourceId`, which is what makes a second
  /// import of the same playlist update the first rather than duplicate it.
  final String id;

  final String name;
  final String description;

  /// A URL at the source. Referenced, never downloaded — see the note on
  /// [ImportedTrack].
  final String? coverUrl;

  /// How many tracks the source says it has. Advisory: it is used to show
  /// progress, and the real count is whatever [MusicImportProvider
  /// .getPlaylistTracks] actually yields.
  final int trackCount;

  final String? ownerName;

  /// Turns this into an AURIX playlist record.
  ///
  /// [id] here is the *Firestore* document id, allocated by the caller — this
  /// object does not know one and must not invent one.
  Playlist toPlaylist({required String id, required MediaSource source}) =>
      Playlist(
        id: id,
        name: name,
        description: description,
        images: <SpotifyImage>[
          if (coverUrl != null && coverUrl!.isNotEmpty)
            SpotifyImage(url: coverUrl!),
        ],
        trackCount: trackCount,
        source: source,
        sourceId: this.id,
      );
}

/// A track as some other service describes it.
///
/// ## What is imported, and what is not
///
/// Metadata and references. A title, an artist, an album name, a duration, a
/// URL to artwork the source already hosts, and the track's id at that source.
///
/// **No audio.** Not a stream, not a cached file, not a re-encode. AURIX does
/// not download audio from Spotify or YouTube, does not decrypt or circumvent
/// any protection, and stores no audio in Firebase Storage. That is not merely
/// a licensing precaution — it is the reason [sourceId] is carried at all:
/// playback of an imported track is a request to the service that owns it,
/// through that service's own authorised client. See `MusicPlaybackService`.
///
/// [artworkUrl] is likewise a reference to the source's own CDN, rendered by
/// the image cache like any other remote image. Nothing is copied.
class ImportedTrack {
  const ImportedTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.album = '',
    this.durationMs = 0,
    this.artworkUrl,
    this.isExplicit = false,
    this.previewUrl,
    this.albumId,
    this.artistId,
  });

  /// The track's id **at the source**.
  final String id;

  final String title;

  /// The display credit — "Daft Punk, Pharrell Williams", not a list.
  final String artist;

  final String album;
  final int durationMs;

  /// A URL at the source. Referenced, never downloaded.
  final String? artworkUrl;

  final bool isExplicit;

  /// A short audio preview the source publishes for open use, if it does.
  ///
  /// Carried because a licensed preview is the one thing AURIX may stream
  /// itself. Null for almost every track, and never synthesised.
  final String? previewUrl;

  /// The source's ids for the album and artist, when it exposes them. What
  /// makes "go to album" work on an imported row.
  final String? albumId;
  final String? artistId;

  /// Turns this into an AURIX track record.
  ///
  /// The document id is derived rather than passed in — see [TrackKey] — so
  /// that importing the same track twice, from a playlist and from a second
  /// playlist, produces one identity.
  Track toTrack({required MediaSource source}) {
    final documentId = TrackKey.forProvider(source, id);

    return Track(
      id: documentId,
      name: title,
      artists: <Artist>[Artist(id: artistId ?? '', name: artist)],
      durationMs: durationMs,
      album: album.isEmpty && artworkUrl == null
          ? null
          : Album(
              id: albumId ?? '',
              name: album,
              artists: const <Artist>[],
              images: <SpotifyImage>[
                if (artworkUrl != null && artworkUrl!.isNotEmpty)
                  SpotifyImage(url: artworkUrl!),
              ],
            ),
      isExplicit: isExplicit,
      previewUrl: previewUrl,
      source: source,
      sourceId: id,
      spotifyId: source == MediaSource.spotify ? id : null,
      youtubeVideoId: source == MediaSource.youtube ? id : null,
    );
  }
}
