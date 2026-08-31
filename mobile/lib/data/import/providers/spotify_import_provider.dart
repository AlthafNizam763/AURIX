import 'dart:async';

import '../../../core/config/env.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/media_source.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../services/spotify_auth_service.dart';
import '../../services/spotify_playlist_service.dart';
import '../imported_models.dart';
import '../music_import_provider.dart';

/// Brings playlists in from Spotify.
///
/// ## What this is, and what it replaced
///
/// Spotify used to *be* AURIX's backend: the profile, the library, the liked
/// songs, the playlists, the home feed and search all came from the Web API,
/// and signing in to AURIX meant authorizing a Spotify account. This class is
/// what is left of that after the refactor — one optional feature, reached from
/// Settings → Import Music, that reads playlists and writes them into the
/// user's own Firestore library.
///
/// The distinction is not cosmetic. A user who never opens the import screen
/// never authenticates with Spotify, and every screen in AURIX works for them.
///
/// ## The session is the import's, not the app's
///
/// [authenticate] runs Spotify's Authorization Code + PKCE flow, and
/// [disconnect] clears the tokens it produced. AURIX holds no standing Spotify
/// relationship between imports: the next one authorizes again.
///
/// The exception is deliberate and is documented at [disconnect]: when Spotify
/// is also the active *playback* provider, disconnecting the import session
/// would stop the music. See the note there.
///
/// ## What is imported
///
/// Titles, artists, album names, durations, artwork URLs and Spotify track ids.
/// No audio. AURIX does not download, cache, re-encode or store Spotify audio
/// anywhere, and does not attempt to. A Spotify track imported into AURIX plays
/// through Spotify's own authorised client — that is what the retained
/// `spotifyId` is for.
class SpotifyImportProvider implements MusicImportProvider {
  SpotifyImportProvider({
    required SpotifyAuthService authService,
    required SpotifyPlaylistService playlistService,
  }) : _auth = authService,
       _playlists = playlistService;

  final SpotifyAuthService _auth;
  final SpotifyPlaylistService _playlists;

  /// How many playlists to ask for per page. Spotify's cap for this endpoint.
  static const int _playlistPageSize = 50;

  /// How many tracks per page. Also Spotify's cap.
  static const int _trackPageSize = 50;

  /// A ceiling on one playlist's import.
  ///
  /// Spotify allows 10,000 tracks in a playlist. Importing one is 200 requests
  /// and 10,000 Firestore writes, and the user is watching a progress bar
  /// throughout. The cap is high enough that no ordinary playlist reaches it
  /// and low enough that a pathological one cannot run for an hour; when it is
  /// hit, the import is reported as partial rather than silently truncated.
  static const int _maxTracksPerPlaylist = 2000;

  @override
  MediaSource get source => MediaSource.spotify;

  @override
  String get displayName => 'Spotify';

  @override
  String get description =>
      'Bring your Spotify playlists into AURIX. Playback of imported tracks '
      'still goes through Spotify.';

  @override
  bool get isAvailable => Env.isSpotifyConfigured;

  @override
  String? get unavailableReason =>
      isAvailable ? null : Env.spotifyConfigurationHint;

  @override
  bool get isConnected => _auth.isAuthenticated;

  @override
  Future<void> authenticate() async {
    if (!isAvailable) {
      throw ImportFailure(
        ImportFailureKind.notConfigured,
        detail: Env.spotifyConfigurationHint,
      );
    }

    // An existing valid session is reused rather than forcing a fresh consent
    // screen. This is the case where the user is importing a second time in one
    // sitting, or where Spotify is already connected for playback.
    if (_auth.isAuthenticated) return;

    try {
      final restored = await _auth.restoreSession();
      if (restored != null) return;
      await _auth.login();
    } on AuthCancelledException {
      throw const ImportFailure(ImportFailureKind.cancelled);
    } on AuthFailedException catch (error) {
      throw ImportFailure(
        ImportFailureKind.authFailed,
        detail: error.debugDetail ?? error.message,
      );
    }
  }

  @override
  Future<List<ImportedPlaylist>> getPlaylists() async {
    final all = <ImportedPlaylist>[];
    var offset = 0;

    try {
      while (true) {
        final page = await _playlists.myPlaylists(
          limit: _playlistPageSize,
          offset: offset,
        );

        for (final playlist in page.items) {
          if (playlist.id.isEmpty) continue;
          all.add(_describe(playlist));
        }

        // A short page is the last one. Spotify's `next` is also authoritative
        // but is absent on some responses, so the length check is what actually
        // terminates the loop.
        if (page.items.length < _playlistPageSize) break;
        offset += _playlistPageSize;

        // A guard against a paging bug turning into an unbounded loop against
        // someone else's API.
        if (offset > 2000) break;
      }
    } on ApiException catch (error) {
      throw _failureFrom(error);
    }

    AppLogger.info('Spotify offered ${all.length} playlists', scope: 'import');
    return all;
  }

  @override
  Future<List<ImportedTrack>> getPlaylistTracks(
    String playlistId, {
    void Function(int fetched, int total)? onProgress,
  }) async {
    final tracks = <ImportedTrack>[];
    var offset = 0;
    var total = 0;

    try {
      while (tracks.length < _maxTracksPerPlaylist) {
        final page = await _playlists.playlistItemsPage(
          playlistId,
          limit: _trackPageSize,
          offset: offset,
        );

        // Null means Spotify refused to enumerate this playlist. Distinct from
        // an empty page, which means the playlist has nothing in it.
        if (page == null) {
          if (tracks.isEmpty) {
            throw const ImportFailure(ImportFailureKind.forbidden);
          }
          AppLogger.warn(
            'Spotify stopped serving "$playlistId" after ${tracks.length} '
            'tracks; importing what arrived',
            scope: 'import',
          );
          break;
        }

        if (page.total > 0) total = page.total;

        for (final item in page.items) {
          final track = item.track;
          // Skipped rather than imported as a blank row:
          //  * a null track is one removed from Spotify's catalogue;
          //  * a local file has no id and cannot be played or looked up;
          //  * an empty id would collide with every other empty id in
          //    `TrackKey`, merging unrelated songs into one document.
          if (track == null || item.isLocal || track.id.isEmpty) continue;
          tracks.add(_describeTrack(track));
        }

        onProgress?.call(tracks.length, total == 0 ? tracks.length : total);

        if (page.items.length < _trackPageSize) break;
        offset += _trackPageSize;
      }
    } on ImportFailure {
      rethrow;
    } on ApiException catch (error) {
      throw _failureFrom(error);
    }

    if (tracks.length >= _maxTracksPerPlaylist) {
      AppLogger.warn(
        'Playlist "$playlistId" hit the $_maxTracksPerPlaylist-track import '
        'cap; the rest was not imported',
        scope: 'import',
      );
    }

    return tracks;
  }

  @override
  Future<void> disconnect() async {
    // Clears the tokens and the stored session — see `SpotifyAuthService
    // .clearSession`.
    //
    // ## Why the caller decides when this runs
    //
    // Spotify is currently also AURIX's playback provider for full tracks:
    // App Remote and Spotify Connect both need a live Spotify authorization,
    // and revoking it mid-song stops the music. `MusicImportController` is
    // therefore what calls this, and it skips it while Spotify playback is
    // active — see the note there.
    //
    // This is a temporary coupling and is the only one left. When playback
    // moves to a provider that is not Spotify, this becomes unconditional and
    // the check in the controller is deleted with it.
    await _auth.clearSession();
    AppLogger.info('Spotify import session cleared', scope: 'import');
  }

  // ---- Mapping -----------------------------------------------------------

  ImportedPlaylist _describe(Playlist playlist) => ImportedPlaylist(
    id: playlist.id,
    name: playlist.name,
    // Spotify descriptions carry HTML entities and anchor tags. Flattened here
    // rather than at render time, because this string is about to be written
    // to Firestore and read back by screens that render it as plain text.
    description: _plainText(playlist.description),
    coverUrl: playlist.imageUrl,
    trackCount: playlist.trackCount,
    ownerName: playlist.owner?.displayName,
  );

  ImportedTrack _describeTrack(Track track) => ImportedTrack(
    id: track.id,
    title: track.name,
    artist: track.artistNames,
    album: track.album?.name ?? '',
    durationMs: track.durationMs,
    artworkUrl: track.artworkUrl,
    isExplicit: track.isExplicit,
    previewUrl: track.previewUrl,
    albumId: track.album?.id,
    artistId: track.primaryArtist?.id,
  );

  /// Strips the HTML Spotify allows in a playlist description.
  static String _plainText(String value) {
    if (value.isEmpty) return value;
    return value
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#39;', "'")
        .trim();
  }

  ImportFailure _failureFrom(ApiException error) {
    final kind = switch (error.kind) {
      ApiFailureKind.unauthorized => ImportFailureKind.authFailed,
      ApiFailureKind.forbidden => ImportFailureKind.forbidden,
      ApiFailureKind.offline || ApiFailureKind.timeout =>
        ImportFailureKind.network,
      ApiFailureKind.rateLimited => ImportFailureKind.rateLimited,
      _ => ImportFailureKind.unknown,
    };
    return ImportFailure(
      kind,
      detail: '${error.statusCode ?? ''} ${error.message}',
      retryAfter: error.retryAfter,
    );
  }
}
