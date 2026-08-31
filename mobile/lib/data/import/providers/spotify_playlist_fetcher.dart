import 'dart:async';

import '../../../core/config/env.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/playlist.dart';
import '../../models/track.dart';
import '../../services/spotify_auth_service.dart';
import '../../services/spotify_playlist_service.dart';
import '../imported_models.dart';
import '../music_import_provider.dart';
import '../playlist_fetcher.dart';
import '../playlist_url.dart';

/// Fetches one Spotify playlist by id.
///
/// ## Authorization
///
/// Spotify's Authorization Code + PKCE flow, through the existing
/// [SpotifyAuthService] — the same one the account-shaped import already uses.
/// Nothing new is stored and no second credential path is introduced.
///
/// The properties that matter, stated plainly because they are requirements
/// rather than incidental:
///
///  * AURIX never sees or asks for a Spotify password. The credential is
///    entered on Spotify's own page, in a browser AURIX cannot read.
///  * There is no client secret in the app. PKCE is the flow Spotify documents
///    for public clients precisely so that none is needed.
///  * Tokens live in platform secure storage (Keychain / EncryptedSharedPrefs)
///    and **never** in Firestore. See [SpotifyAuthService].
///  * A private playlist needs `playlist-read-private`, which is in the scope
///    set requested at authorization. Without it, Spotify's refusal surfaces as
///    [ImportFailureKind.private] rather than as a generic failure.
///
/// ## Paging
///
/// `GET /playlists/{id}/items`, followed until the page is short or `next` is
/// null. Both conditions are checked and neither is trusted alone — see
/// [_isLastPage]. A playlist is imported whole; there is no first-page-only
/// path.
///
/// ## No audio, ever
///
/// Titles, artists, album names, durations, artwork URLs and Spotify track ids.
/// AURIX does not download, decrypt, cache, re-encode or re-host Spotify audio,
/// and stores none in Firebase Storage. The retained track id exists so an
/// authorised Spotify player can be asked to play the song — it is not a handle
/// for fetching a stream.
class SpotifyPlaylistFetcher implements PlaylistFetcher {
  SpotifyPlaylistFetcher({
    required SpotifyAuthService authService,
    required SpotifyPlaylistService playlistService,
  }) : _auth = authService,
       _playlists = playlistService;

  final SpotifyAuthService _auth;
  final SpotifyPlaylistService _playlists;

  /// Spotify's maximum page size for this endpoint.
  static const int _pageSize = 50;

  /// A ceiling on one import.
  ///
  /// Spotify permits 10,000 items in a playlist. Importing one would be 200
  /// requests and 10,000 Firestore writes with the user watching a progress
  /// bar. High enough that no ordinary playlist reaches it, low enough that a
  /// pathological one cannot run for an hour — and when it is hit the result is
  /// reported as partial rather than silently truncated.
  static const int _maxTracks = 2000;

  /// The prefix Spotify uses for its own editorial and algorithmic playlists.
  ///
  /// Today's Top Hits, RapCaviar, Discover Weekly, Release Radar and every
  /// "made for you" mix live in this namespace. Since 27 November 2024 Spotify
  /// refuses them to applications in Development Mode, answering `404` — the
  /// same status as a deleted playlist.
  ///
  /// Those two cases need different messages: one is "check your link", the
  /// other is "this can never work without extended access". The id is the only
  /// thing that distinguishes them before the request is made, so it is what
  /// this uses. See [ImportFailureKind.editorialRestricted].
  static const String _editorialPrefix = '37i9dQZF1';

  @override
  PlaylistSource get source => PlaylistSource.spotify;

  @override
  bool get isAvailable => Env.isSpotifyConfigured;

  @override
  String? get unavailableReason =>
      isAvailable ? null : Env.spotifyConfigurationHint;

  /// True for a playlist id in Spotify's own editorial namespace.
  static bool isEditorialPlaylist(String playlistId) =>
      playlistId.startsWith(_editorialPrefix);

  @override
  Future<FetchedPlaylist> fetch(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  }) async {
    if (!isAvailable) {
      throw ImportFailure(
        ImportFailureKind.notConfigured,
        detail: Env.spotifyConfigurationHint,
      );
    }

    await _ensureAuthorized();

    onProgress?.call(const FetchProgress(stage: FetchStage.metadata));

    final playlist = await _fetchMetadata(playlistId);
    final tracks = await _fetchItems(playlistId, onProgress: onProgress);

    return FetchedPlaylist(
      playlist: ImportedPlaylist(
        id: playlistId,
        name: playlist.name,
        description: _plainText(playlist.description),
        coverUrl: playlist.imageUrl,
        // The source's own count can disagree with what was actually
        // enumerable — removed tracks and local files are counted by Spotify
        // and skipped here. What was really imported is authoritative.
        trackCount: tracks.length,
        ownerName: playlist.owner?.displayName,
      ),
      tracks: tracks,
    );
  }

  // ---- Authorization -----------------------------------------------------

  /// Makes sure there is a live Spotify session, running the consent flow only
  /// if there is not.
  ///
  /// A stored session is restored first, so a user who imported ten minutes ago
  /// is not sent through the consent screen again. Nothing here bypasses
  /// Spotify's authorization: the only way a token is obtained is the flow
  /// Spotify itself serves.
  Future<void> _ensureAuthorized() async {
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

  // ---- Metadata ----------------------------------------------------------

  Future<Playlist> _fetchMetadata(String playlistId) async {
    try {
      return await _playlists.playlist(playlistId);
    } on ApiException catch (error) {
      throw _failureFor(error, playlistId);
    }
  }

  // ---- Items -------------------------------------------------------------

  Future<List<ImportedTrack>> _fetchItems(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  }) async {
    final tracks = <ImportedTrack>[];
    var offset = 0;
    var total = 0;

    try {
      while (tracks.length < _maxTracks) {
        final page = await _playlists.playlistItemsPage(
          playlistId,
          limit: _pageSize,
          offset: offset,
        );

        // Null means Spotify refused to enumerate this playlist at all — a
        // different answer from an empty page, which means the playlist really
        // has nothing in it. Rendering "this playlist is empty" over a refusal
        // is the bug this distinction prevents.
        if (page == null) {
          if (tracks.isEmpty) {
            throw ImportFailure(
              isEditorialPlaylist(playlistId)
                  ? ImportFailureKind.editorialRestricted
                  : ImportFailureKind.forbidden,
              detail: 'Spotify refused both /items and /tracks for $playlistId',
            );
          }
          // Partial rather than nothing: the user keeps what arrived.
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
          //  * a null track was removed from Spotify's catalogue;
          //  * a local file has no id and can be neither played nor looked up;
          //  * an empty id would collide with every other empty id in the
          //    catalogue key and merge unrelated songs into one document.
          if (track == null || item.isLocal || track.id.isEmpty) continue;
          tracks.add(_describe(track));
        }

        onProgress?.call(
          FetchProgress(
            stage: FetchStage.items,
            fetched: tracks.length,
            total: total == 0 ? tracks.length : total,
          ),
        );

        if (_isLastPage(page.items.length, page.next)) break;
        offset += _pageSize;
      }
    } on ImportFailure {
      rethrow;
    } on ApiException catch (error) {
      throw _failureFor(error, playlistId);
    }

    if (tracks.length >= _maxTracks) {
      AppLogger.warn(
        'Playlist "$playlistId" hit the $_maxTracks-track import cap; the '
        'rest was not imported',
        scope: 'import',
      );
    }

    return tracks;
  }

  /// Whether paging should stop.
  ///
  /// Both signals are consulted because neither is reliable alone. `next` is
  /// Spotify's own answer and is authoritative when present — but it is absent
  /// from some responses, and a loop that trusted only it would stop after one
  /// page. A short page is the structural signal and is absent in the opposite
  /// case: a page that drops filtered entries can be short while more remain.
  ///
  /// Stopping when *either* says "done" is the conservative combination, and it
  /// is what makes the loop terminate against both behaviours.
  static bool _isLastPage(int itemsOnPage, String? next) =>
      next == null || itemsOnPage < _pageSize;

  // ---- Mapping -----------------------------------------------------------

  ImportedTrack _describe(Track track) => ImportedTrack(
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

  /// Strips the HTML Spotify allows inside a playlist description.
  ///
  /// Done here rather than at render time because this string is about to be
  /// written to Firestore and read back by screens that render it as plain
  /// text.
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

  /// Turns a transport failure into the reason the user is shown.
  ///
  /// The `404` branch is the one that earns its keep. Spotify answers `404`
  /// both for a playlist that does not exist and for one its own editorial
  /// namespace hides from Development Mode applications, and the two need
  /// completely different messages — "check your link" versus "this needs
  /// extended access". The id is what tells them apart.
  ImportFailure _failureFor(ApiException error, String playlistId) {
    final kind = switch (error.kind) {
      ApiFailureKind.notFound => isEditorialPlaylist(playlistId)
          ? ImportFailureKind.editorialRestricted
          : ImportFailureKind.notFound,
      ApiFailureKind.forbidden => isEditorialPlaylist(playlistId)
          ? ImportFailureKind.editorialRestricted
          : ImportFailureKind.private,
      ApiFailureKind.unauthorized => ImportFailureKind.authFailed,
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
