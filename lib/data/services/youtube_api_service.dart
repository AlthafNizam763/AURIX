import 'dart:async';

import 'package:dio/dio.dart';

import '../../core/config/env.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/app_logger.dart';
import '../models/json_utils.dart';

/// One entry in a YouTube playlist, as the Data API describes it.
class YouTubePlaylistItem {
  const YouTubePlaylistItem({
    required this.videoId,
    required this.title,
    required this.position,
    this.description = '',
    this.thumbnailUrl,
    this.channelTitle = '',
    this.videoOwnerChannelTitle,
    this.privacyStatus,
  });

  final String videoId;
  final String title;
  final String description;
  final String? thumbnailUrl;

  /// Zero-based index within the playlist. What the import writes into
  /// `position`, and therefore what Next/Previous follow.
  final int position;

  /// The channel that owns the *playlist*.
  final String channelTitle;

  /// The channel that owns the *video* — the artist, on a music upload.
  ///
  /// The more useful of the two and the reason both are carried: on a playlist
  /// someone else compiled, `channelTitle` is the compiler and this is the
  /// artist.
  final String? videoOwnerChannelTitle;

  /// `public`, `private` or `privacyStatusUnspecified`.
  ///
  /// Read from `status` so deleted and private entries can be skipped rather
  /// than imported as rows with a title of "Deleted video" — which is exactly
  /// what the API returns for them.
  final String? privacyStatus;

  /// True for an entry that cannot be played or looked up.
  ///
  /// YouTube leaves tombstones in playlists: an entry whose video was deleted
  /// or made private keeps its slot and comes back titled "Deleted video" or
  /// "Private video", with no thumbnail. Importing those would put unplayable
  /// rows in the user's library forever, so they are dropped — which is why
  /// an imported YouTube playlist can legitimately be shorter than its
  /// `itemCount` says.
  bool get isUnavailable {
    if (videoId.isEmpty) return true;
    final status = privacyStatus?.toLowerCase();
    if (status == 'private') return true;
    final normalised = title.trim().toLowerCase();
    return normalised == 'deleted video' || normalised == 'private video';
  }
}

/// A YouTube playlist's own metadata.
class YouTubePlaylistDetails {
  const YouTubePlaylistDetails({
    required this.id,
    required this.title,
    this.description = '',
    this.thumbnailUrl,
    this.channelTitle = '',
    this.itemCount = 0,
  });

  final String id;
  final String title;
  final String description;
  final String? thumbnailUrl;
  final String channelTitle;
  final int itemCount;
}

/// One page of playlist items.
class YouTubePage {
  const YouTubePage({
    required this.items,
    this.nextPageToken,
    this.totalResults = 0,
  });

  final List<YouTubePlaylistItem> items;

  /// Null on the last page. The only termination signal the Data API offers —
  /// there is no offset and no total-pages count.
  final String? nextPageToken;

  final int totalResults;
}

/// The YouTube Data API v3, for playlist import only.
///
/// ## What it is authorised to do, and what it must never do
///
/// Reads public playlist and video **metadata** with an API key. Titles,
/// descriptions, thumbnails, channel names, positions, durations.
///
/// It does not and must not touch audio or video streams. No downloading, no
/// extraction, no re-encoding, no `youtube-dl`-class tooling, nothing written
/// to Firebase Storage, and nothing that circumvents YouTube's protections or
/// its Terms of Service. The video id is carried so an authorised YouTube
/// player can be handed the video — it is not a handle for fetching a stream.
///
/// ## Why an API key and not OAuth
///
/// The feature is "paste a link to a playlist". A public playlist is public: an
/// API key reaches it, and requiring a Google sign-in before AURIX will read a
/// link the user already has would be friction with nothing behind it.
///
/// The cost is that **private playlists are not importable this way** — they
/// need OAuth with `youtube.readonly`, and the user's own consent. That is
/// surfaced as [ImportFailureKind.private] rather than being papered over, and
/// the OAuth path is the documented next step. `Env.youTubeClientId` already
/// exists for it.
///
/// ## Its own HTTP client, deliberately
///
/// Constructed with a plain [Dio] rather than the app's shared
/// `spotifyDioProvider`. That instance attaches the user's Spotify bearer token
/// to everything it sends, and Google must never receive it. This is the same
/// reasoning that gives the lyrics provider its own client.
class YouTubeApiService {
  YouTubeApiService({Dio? client, String? apiKey})
      : _dio = client ?? _defaultClient(),
        _apiKey = apiKey ?? Env.youTubeApiKey;

  final Dio _dio;
  final String _apiKey;

  static const String baseUrl = 'https://www.googleapis.com/youtube/v3';

  /// The API's maximum page size for `playlistItems.list`.
  static const int pageSize = 50;

  /// The cap on ids per `videos.list` call.
  static const int _videoBatchSize = 50;

  static Dio _defaultClient() => Dio(
    BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 20),
      // Non-2xx is handled below rather than thrown as a transport error, so
      // the quota and privacy cases can be told apart by status.
      validateStatus: (status) => status != null && status < 500,
    ),
  );

  bool get isConfigured => _apiKey.isNotEmpty;

  // -------------------------------------------------------------------------
  // Playlist metadata
  // -------------------------------------------------------------------------

  /// `GET /playlists?part=snippet,contentDetails&id={id}`
  ///
  /// Returns null when the playlist is not visible — deleted, private, or an
  /// id that never existed. The API answers `200` with an empty `items` array
  /// for all three, which is why this is a null return rather than a throw.
  Future<YouTubePlaylistDetails?> playlist(String playlistId) async {
    final data = await _get('/playlists', <String, dynamic>{
      'part': 'snippet,contentDetails,status',
      'id': playlistId,
      'maxResults': 1,
    });

    final items = data['items'];
    if (items is! List || items.isEmpty) return null;

    final item = items.first;
    if (item is! Map<String, dynamic>) return null;

    final snippet = Json.obj(item, 'snippet') ?? const <String, dynamic>{};
    final contentDetails =
        Json.obj(item, 'contentDetails') ?? const <String, dynamic>{};

    return YouTubePlaylistDetails(
      id: Json.str(item, 'id', fallback: playlistId),
      title: Json.str(snippet, 'title', fallback: 'Untitled playlist'),
      description: Json.str(snippet, 'description'),
      thumbnailUrl: _bestThumbnail(Json.obj(snippet, 'thumbnails')),
      channelTitle: Json.str(snippet, 'channelTitle'),
      itemCount: Json.intVal(contentDetails, 'itemCount'),
    );
  }

  // -------------------------------------------------------------------------
  // Playlist items
  // -------------------------------------------------------------------------

  /// `GET /playlistItems?part=snippet,contentDetails,status&playlistId={id}`
  ///
  /// One page. [pageToken] is null for the first; the caller follows
  /// [YouTubePage.nextPageToken] until it comes back null.
  Future<YouTubePage> playlistItems(
    String playlistId, {
    String? pageToken,
  }) async {
    final data = await _get('/playlistItems', <String, dynamic>{
      // All three parts are requested because each carries something the
      // import needs and none carries all of it:
      //   snippet        — title, description, thumbnails, position, channel
      //   contentDetails — videoId (the only reliable place it appears)
      //   status         — privacyStatus, which is how a private entry is
      //                    told apart from a playable one
      'part': 'snippet,contentDetails,status',
      'playlistId': playlistId,
      'maxResults': pageSize,
      'pageToken': ?pageToken,
    });

    final rawItems = data['items'];
    final pageInfo = Json.obj(data, 'pageInfo') ?? const <String, dynamic>{};

    final items = <YouTubePlaylistItem>[];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (raw is! Map<String, dynamic>) continue;
        final parsed = _parseItem(raw);
        if (parsed != null) items.add(parsed);
      }
    }

    return YouTubePage(
      items: items,
      nextPageToken: Json.strOrNull(data, 'nextPageToken'),
      totalResults: Json.intVal(pageInfo, 'totalResults'),
    );
  }

  static YouTubePlaylistItem? _parseItem(Map<String, dynamic> raw) {
    final snippet = Json.obj(raw, 'snippet');
    if (snippet == null) return null;

    final contentDetails = Json.obj(raw, 'contentDetails');
    final status = Json.obj(raw, 'status');

    // `contentDetails.videoId` is the canonical location. `snippet.resourceId
    // .videoId` carries the same value and is the only one present on some
    // older responses, so it is the fallback rather than the primary.
    final videoId = Json.strOrNull(contentDetails ?? const {}, 'videoId') ??
        Json.strOrNull(
          Json.obj(snippet, 'resourceId') ?? const <String, dynamic>{},
          'videoId',
        ) ??
        '';

    return YouTubePlaylistItem(
      videoId: videoId,
      title: Json.str(snippet, 'title'),
      description: Json.str(snippet, 'description'),
      thumbnailUrl: _bestThumbnail(Json.obj(snippet, 'thumbnails')),
      position: Json.intVal(snippet, 'position'),
      channelTitle: Json.str(snippet, 'channelTitle'),
      videoOwnerChannelTitle:
          Json.strOrNull(snippet, 'videoOwnerChannelTitle'),
      privacyStatus:
          status == null ? null : Json.strOrNull(status, 'privacyStatus'),
    );
  }

  // -------------------------------------------------------------------------
  // Durations
  // -------------------------------------------------------------------------

  /// Durations in milliseconds, keyed by video id.
  ///
  /// A second request because `playlistItems` does not carry duration — it is
  /// on the *video*, not on the playlist entry. Batched at fifty ids per call,
  /// which is the API's cap, so a 200-track playlist costs four extra requests
  /// rather than two hundred.
  ///
  /// Failures are swallowed and reported as an absent entry rather than as an
  /// error. A song with no duration renders as `--:--` and plays perfectly
  /// well; failing the whole import over a cosmetic field would be the wrong
  /// trade.
  Future<Map<String, int>> videoDurations(List<String> videoIds) async {
    final durations = <String, int>{};
    if (videoIds.isEmpty) return durations;

    for (var start = 0; start < videoIds.length; start += _videoBatchSize) {
      final end = (start + _videoBatchSize).clamp(0, videoIds.length);
      final batch = videoIds.sublist(start, end);

      try {
        final data = await _get('/videos', <String, dynamic>{
          'part': 'contentDetails',
          'id': batch.join(','),
          'maxResults': _videoBatchSize,
        });

        final items = data['items'];
        if (items is! List) continue;

        for (final raw in items) {
          if (raw is! Map<String, dynamic>) continue;
          final id = Json.strOrNull(raw, 'id');
          final details = Json.obj(raw, 'contentDetails');
          if (id == null || details == null) continue;

          final iso = Json.strOrNull(details, 'duration');
          if (iso == null) continue;

          final ms = parseIso8601Duration(iso);
          if (ms > 0) durations[id] = ms;
        }
      } on Object catch (error) {
        AppLogger.warn(
          'Could not read durations for ${batch.length} videos',
          scope: 'import',
          error: error,
        );
      }
    }

    return durations;
  }

  /// Parses an ISO-8601 duration (`PT3M52S`) to milliseconds.
  ///
  /// The only format YouTube reports a duration in. Hours, minutes and seconds
  /// are all optional and any of them can be absent — `PT4M`, `PT47S` and
  /// `PT1H2M3S` are all real responses — so each is matched independently
  /// rather than by one positional pattern.
  ///
  /// Days appear on the rare very long upload (`P1DT2H`) and are handled.
  /// Returns 0 for anything unparseable, which renders as an unknown duration
  /// rather than as a wrong one.
  static int parseIso8601Duration(String iso) {
    final match = RegExp(
      r'^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$',
      caseSensitive: false,
    ).firstMatch(iso.trim());

    if (match == null) return 0;

    final days = int.tryParse(match.group(1) ?? '') ?? 0;
    final hours = int.tryParse(match.group(2) ?? '') ?? 0;
    final minutes = int.tryParse(match.group(3) ?? '') ?? 0;
    final seconds = double.tryParse(match.group(4) ?? '') ?? 0;

    return Duration(
      days: days,
      hours: hours,
      minutes: minutes,
      milliseconds: (seconds * 1000).round(),
    ).inMilliseconds;
  }

  // -------------------------------------------------------------------------
  // Transport
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, dynamic> query,
  ) async {
    if (!isConfigured) {
      throw const ApiException(
        kind: ApiFailureKind.unauthorized,
        message: 'YouTube import is not configured in this build.',
        debugDetail: 'YOUTUBE_API_KEY is empty',
      );
    }

    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        path,
        queryParameters: <String, dynamic>{...query, 'key': _apiKey},
      );
    } on DioException catch (error) {
      throw ApiException(
        kind: switch (error.type) {
          DioExceptionType.connectionTimeout ||
          DioExceptionType.receiveTimeout ||
          DioExceptionType.sendTimeout => ApiFailureKind.timeout,
          DioExceptionType.connectionError => ApiFailureKind.offline,
          DioExceptionType.cancel => ApiFailureKind.cancelled,
          _ => ApiFailureKind.unknown,
        },
        message: 'Could not reach YouTube.',
        debugDetail: error.message,
        endpoint: path,
      );
    }

    final status = response.statusCode ?? 0;
    if (status >= 400) throw _errorFor(status, response.data, path);

    final data = response.data;
    if (data is! Map<String, dynamic>) {
      throw ApiException(
        kind: ApiFailureKind.parsing,
        message: 'YouTube sent a response AURIX could not read.',
        statusCode: status,
        endpoint: path,
      );
    }

    return data;
  }

  /// Maps a Google API error onto the app's failure vocabulary.
  ///
  /// The `403` branch matters most, because Google uses one status for two
  /// unrelated problems and the fixes are opposite: `quotaExceeded` means wait
  /// until tomorrow, while a key/referrer problem means fix the Cloud console.
  /// The machine-readable `reason` is what separates them, so it is read rather
  /// than the status alone.
  ApiException _errorFor(int status, Object? body, String path) {
    String? reason;
    String? apiMessage;

    if (body is Map<String, dynamic>) {
      final error = Json.obj(body, 'error');
      if (error != null) {
        apiMessage = Json.strOrNull(error, 'message');
        final errors = error['errors'];
        if (errors is List && errors.isNotEmpty) {
          final first = errors.first;
          if (first is Map<String, dynamic>) {
            reason = Json.strOrNull(first, 'reason');
          }
        }
      }
    }

    final kind = switch (status) {
      403 when reason == 'quotaExceeded' ||
          reason == 'dailyLimitExceeded' ||
          reason == 'rateLimitExceeded' => ApiFailureKind.rateLimited,
      403 => ApiFailureKind.forbidden,
      404 => ApiFailureKind.notFound,
      429 => ApiFailureKind.rateLimited,
      400 => ApiFailureKind.unknown,
      _ => ApiFailureKind.unknown,
    };

    AppLogger.warn(
      'YouTube $status on $path (reason=$reason)',
      scope: 'import',
      error: apiMessage,
    );

    return ApiException(
      kind: kind,
      message: 'YouTube refused the request.',
      statusCode: status,
      reason: reason,
      apiMessage: apiMessage,
      endpoint: path,
    );
  }

  /// The largest thumbnail the response offers.
  ///
  /// YouTube returns a fixed ladder of renditions and omits the larger ones for
  /// older or lower-resolution uploads, so this walks down rather than assuming
  /// any particular key exists.
  static String? _bestThumbnail(Map<String, dynamic>? thumbnails) {
    if (thumbnails == null) return null;
    for (final key in const <String>[
      'maxres',
      'standard',
      'high',
      'medium',
      'default',
    ]) {
      final entry = Json.obj(thumbnails, key);
      final url = entry == null ? null : Json.strOrNull(entry, 'url');
      if (url != null && url.isNotEmpty) return url;
    }
    return null;
  }
}
