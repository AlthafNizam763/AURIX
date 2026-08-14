import 'dart:async';

import '../../../core/config/env.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/song_key.dart';
import '../../services/youtube_api_service.dart';
import '../imported_models.dart';
import '../music_import_provider.dart';
import '../playlist_fetcher.dart';
import '../playlist_url.dart';

/// Fetches one YouTube / YouTube Music playlist by id.
///
/// ## Paging
///
/// `playlistItems.list` is cursor-paged: there is no offset and no page count,
/// only a `nextPageToken` that is absent on the last page. The loop follows it
/// until it comes back null, which is the *only* correct termination condition
/// — a short page is not a signal here, because unavailable entries are
/// filtered out of a page after the API has already counted them.
///
/// ## Metadata quality, and the honest limits of it
///
/// A YouTube video title is a string an uploader typed. It is not a structured
/// record, and turning `Artist - Title (Official Video)` into two fields is a
/// heuristic that will sometimes be wrong. Since a wrong split lives in the
/// user's library indefinitely, [_describe] is deliberately conservative:
///
///  * The `Artist - Title` convention is applied only when the video's own
///    channel corroborates it, or when the channel is an auto-generated
///    `… - Topic` artist channel (which YouTube creates for real releases and
///    which is therefore trustworthy).
///  * Otherwise the raw title is kept as the song title and the channel is
///    credited as the artist. Less tidy, and correct.
///
/// Guessing harder than this produces confidently mangled metadata, which is
/// worse than untidy metadata because the user cannot tell it is wrong.
///
/// ## No audio, ever
///
/// Metadata and references only. No stream downloading, no extraction, no
/// re-encoding, no circumvention of YouTube's protections or Terms of Service,
/// and nothing written to Firebase Storage. The video id is carried so an
/// authorised YouTube player can be handed the video.
class YouTubePlaylistFetcher implements PlaylistFetcher {
  YouTubePlaylistFetcher({required YouTubeApiService api}) : _api = api;

  final YouTubeApiService _api;

  /// A ceiling on one import, matching the Spotify fetcher's.
  static const int _maxTracks = 2000;

  /// A guard against a paging bug becoming an unbounded loop against someone
  /// else's API. At fifty per page this is well past the track cap.
  static const int _maxPages = 60;

  @override
  PlaylistSource get source => PlaylistSource.youtube;

  @override
  bool get isAvailable => Env.isYouTubeConfigured;

  @override
  String? get unavailableReason =>
      isAvailable ? null : Env.youTubeConfigurationHint;

  @override
  Future<FetchedPlaylist> fetch(
    String playlistId, {
    void Function(FetchProgress progress)? onProgress,
  }) async {
    if (!isAvailable) {
      throw ImportFailure(
        ImportFailureKind.notConfigured,
        detail: Env.youTubeConfigurationHint,
      );
    }

    onProgress?.call(const FetchProgress(stage: FetchStage.metadata));

    final YouTubePlaylistDetails? details;
    try {
      details = await _api.playlist(playlistId);
    } on ApiException catch (error) {
      throw _failureFor(error);
    }

    // An empty `items` array is how the API reports all three of "deleted",
    // "private" and "never existed". They cannot be distinguished from the
    // response, so the message covers both plausible fixes rather than
    // asserting one.
    if (details == null) {
      throw const ImportFailure(
        ImportFailureKind.notFound,
        detail: 'playlists.list returned no items',
      );
    }

    final items = await _fetchItems(
      playlistId,
      declaredTotal: details.itemCount,
      onProgress: onProgress,
    );

    final durations = await _api.videoDurations(
      items.map((item) => item.videoId).toList(growable: false),
    );

    final tracks = items
        .map((item) => _describe(item, durations[item.videoId] ?? 0))
        .toList(growable: false);

    return FetchedPlaylist(
      playlist: ImportedPlaylist(
        id: playlistId,
        name: details.title,
        description: details.description,
        coverUrl: details.thumbnailUrl,
        // What was actually importable, not what the API counted. The two
        // differ whenever the playlist holds deleted or private entries, and
        // the honest number is the one the user will be able to play.
        trackCount: tracks.length,
        ownerName: details.channelTitle,
      ),
      tracks: tracks,
    );
  }

  // ---- Paging ------------------------------------------------------------

  Future<List<YouTubePlaylistItem>> _fetchItems(
    String playlistId, {
    required int declaredTotal,
    void Function(FetchProgress progress)? onProgress,
  }) async {
    final items = <YouTubePlaylistItem>[];
    var skipped = 0;
    String? pageToken;
    var pages = 0;

    try {
      do {
        final page = await _api.playlistItems(playlistId, pageToken: pageToken);

        for (final item in page.items) {
          // Tombstones for deleted and private videos keep their slot in the
          // playlist and come back titled "Deleted video". Importing them
          // would put permanently unplayable rows in the library.
          if (item.isUnavailable) {
            skipped++;
            continue;
          }
          items.add(item);
          if (items.length >= _maxTracks) break;
        }

        onProgress?.call(
          FetchProgress(
            stage: FetchStage.items,
            fetched: items.length,
            total: declaredTotal > 0 ? declaredTotal : page.totalResults,
          ),
        );

        pageToken = page.nextPageToken;
        pages++;
      } while (pageToken != null &&
          items.length < _maxTracks &&
          pages < _maxPages);
    } on ApiException catch (error) {
      // A failure part-way through keeps what arrived rather than discarding
      // it, on the same reasoning as the Spotify fetcher: a partial playlist
      // the user can see and re-sync beats an error and nothing.
      if (items.isEmpty) throw _failureFor(error);
      AppLogger.warn(
        'YouTube stopped serving "$playlistId" after ${items.length} items; '
        'importing what arrived',
        scope: 'import',
        error: error,
      );
    }

    if (skipped > 0) {
      AppLogger.info(
        'Skipped $skipped deleted or private ${skipped == 1 ? 'video' : 'videos'} '
        'in playlist $playlistId',
        scope: 'import',
      );
    }

    // The API returns items in playlist order, but `position` is the field
    // that actually defines it and a page boundary is exactly where an
    // assumption about ordering would break. Sorted explicitly.
    items.sort((a, b) => a.position.compareTo(b.position));
    return items;
  }

  // ---- Mapping -----------------------------------------------------------

  /// Turns one video into a described track.
  ///
  /// See the class comment for why the artist/title split is applied only when
  /// something corroborates it.
  ImportedTrack _describe(YouTubePlaylistItem item, int durationMs) {
    final channel = (item.videoOwnerChannelTitle ?? item.channelTitle).trim();
    final isTopicChannel =
        RegExp(r'\s-\s*topic\s*$', caseSensitive: false).hasMatch(channel);

    // A `… - Topic` channel is auto-generated by YouTube for a real release
    // delivered by a distributor. Its name is the artist, verbatim, and its
    // video titles are the track titles without the uploader decoration that
    // makes ordinary uploads hard to parse. So it is trusted directly.
    if (isTopicChannel) {
      return ImportedTrack(
        id: item.videoId,
        title: item.title.trim(),
        artist: channel.replaceAll(
          RegExp(r'\s-\s*topic\s*$', caseSensitive: false),
          '',
        ).trim(),
        durationMs: durationMs,
        artworkUrl: item.thumbnailUrl,
      );
    }

    final split = SongKey.splitVideoTitle(item.title);

    // The split is accepted only when the leading segment matches the channel
    // that published the video. That is the corroboration: an artist channel
    // titling its own upload `The Weeknd - Blinding Lights` is describing
    // itself, whereas a compilation channel titling one `Best Songs 2024 -
    // Mix` is not, and the two are indistinguishable from the title alone.
    if (split != null && _creditMatchesChannel(split.artist, channel)) {
      return ImportedTrack(
        id: item.videoId,
        title: split.title,
        artist: split.artist,
        durationMs: durationMs,
        artworkUrl: item.thumbnailUrl,
      );
    }

    // Nothing corroborated the convention. The raw title becomes the song
    // title and the channel takes the credit — untidy, but never wrong in a
    // way the user cannot see and correct.
    return ImportedTrack(
      id: item.videoId,
      title: item.title.trim(),
      artist: channel.isEmpty ? 'Unknown artist' : channel,
      durationMs: durationMs,
      artworkUrl: item.thumbnailUrl,
    );
  }

  /// Whether a title's leading segment names the channel that published it.
  ///
  /// Compared after normalisation, so "TheWeeknd", "The Weeknd" and
  /// "TheWeekndVEVO" all agree. Containment rather than equality, because a
  /// VEVO channel appends its own suffix and an artist channel sometimes
  /// carries a qualifier the title does not.
  static bool _creditMatchesChannel(String credit, String channel) {
    final a = SongKey.normaliseArtist(credit).replaceAll(' ', '');
    final b = SongKey.normaliseArtist(channel).replaceAll(' ', '');
    if (a.isEmpty || b.isEmpty) return false;
    return a == b || a.contains(b) || b.contains(a);
  }

  ImportFailure _failureFor(ApiException error) {
    final kind = switch (error.kind) {
      ApiFailureKind.notFound => ImportFailureKind.notFound,
      // A `403` that is not a quota problem, on a *public* read, means the
      // playlist is private — an API key reaches everything public.
      ApiFailureKind.forbidden => ImportFailureKind.private,
      ApiFailureKind.rateLimited => ImportFailureKind.quotaExceeded,
      ApiFailureKind.unauthorized => ImportFailureKind.notConfigured,
      ApiFailureKind.offline || ApiFailureKind.timeout =>
        ImportFailureKind.network,
      _ => ImportFailureKind.unknown,
    };

    return ImportFailure(
      kind,
      detail: '${error.statusCode ?? ''} ${error.apiMessage ?? error.message}',
      retryAfter: error.retryAfter,
    );
  }
}
