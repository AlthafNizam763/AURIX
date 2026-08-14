import 'package:dio/dio.dart';

import '../../core/constants/app_constants.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/error_mapper.dart';
import '../../core/utils/app_logger.dart';

/// Base class for every Spotify Web API service.
///
/// Owns the three things all of them share:
///
/// 1. **One error type.** Every method funnels through [request], so a caller
///    only ever catches [ApiException] — never a `DioException`.
/// 2. **The market parameter.** Spotify's catalogue is per-country. Omitting
///    `market` returns tracks the user cannot play and breaks track relinking,
///    which shows up as songs that silently refuse to start.
/// 3. **Cancellation.** Screens dispose mid-flight constantly (a search
///    superseded by the next keystroke); every method accepts a [CancelToken].
///
/// Services are thin: they map endpoints to models. Composition, caching and
/// fallback logic belong in the repositories above them.
abstract class SpotifyApiService {
  SpotifyApiService(this.dio);

  final Dio dio;

  /// The market to scope catalogue requests to.
  ///
  /// `from_token` asks Spotify to infer the country from the access token,
  /// which is correct before the profile has loaded. Once it has, the
  /// repository swaps in the real ISO code — some endpoints honour an explicit
  /// code more reliably than the token hint.
  static String market = 'from_token';

  static void setMarketFromCountry(String? country) {
    if (country != null && country.length == 2) {
      market = country.toUpperCase();
      AppLogger.debug('Market set to $market', scope: 'api');
    }
  }

  /// Runs a request and maps failures to [ApiException].
  Future<T> request<T>(
    Future<Response<dynamic>> Function() send,
    T Function(Map<String, dynamic> json) parse, {
    T Function()? onEmpty,
  }) async {
    try {
      final response = await send();
      final data = response.data;

      // 204 No Content is a real, meaningful answer from the player endpoints
      // ("nothing is playing"), not an error. Same for a null body on 200.
      if (response.statusCode == 204 || data == null) {
        if (onEmpty != null) return onEmpty();
        throw ApiException(
          kind: ApiFailureKind.parsing,
          message: 'Spotify returned an empty response.',
          statusCode: response.statusCode,
          debugDetail: 'Empty body with no onEmpty handler',
        );
      }

      if (data is! Map<String, dynamic>) {
        throw ApiException(
          kind: ApiFailureKind.parsing,
          message: 'Spotify sent something we could not read.',
          debugDetail: 'Expected object, got ${data.runtimeType}',
        );
      }

      return parse(data);
    } on DioException catch (error) {
      throw ErrorMapper.fromDio(error);
    } on ApiException {
      rethrow;
    } on Object catch (error, stackTrace) {
      AppLogger.error('Unhandled service error', scope: 'api', error: error, stackTrace: stackTrace);
      throw ErrorMapper.fromUnknown(error, stackTrace);
    }
  }

  /// Runs a request whose success is signalled by the status code alone
  /// (the player transport endpoints, library add/remove).
  Future<void> command(Future<Response<dynamic>> Function() send) async {
    try {
      await send();
    } on DioException catch (error) {
      throw ErrorMapper.fromDio(error);
    } on Object catch (error, stackTrace) {
      throw ErrorMapper.fromUnknown(error, stackTrace);
    }
  }

  /// Convenience GET returning a parsed object.
  Future<T> get<T>(
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
    T Function()? onEmpty,
  }) {
    final cleaned = _clean(query);
    return request<T>(
      () => _coalescedGet(path, cleaned, cancelToken),
      parse,
      onEmpty: onEmpty,
    );
  }

  /// GETs in flight right now, by path and query.
  ///
  /// Two callers asking Spotify the same question at the same moment should
  /// cost one request, not two. That is not hypothetical here: the Home feed
  /// fans out its shelves through a single `Future.wait`, and two of those
  /// branches — the "Top artists" shelf and the recommendation seeds — both
  /// reach `GET /me/top/artists`. Because they race inside one `Future.wait`,
  /// no response cache can help: neither has returned when the other starts.
  /// The same shape produces the duplicate `/me/player/devices` reads when the
  /// player screen opens over a shell that is already refreshing devices.
  ///
  /// Coalescing rather than caching, deliberately. The entry lives only for the
  /// duration of the request, so this never serves a stale answer and never has
  /// to be invalidated — a second caller either joins a flight already in the
  /// air or starts its own.
  static final Map<String, Future<Response<dynamic>>> _inFlightGets =
      <String, Future<Response<dynamic>>>{};

  /// Requests carrying a [CancelToken] are excluded.
  ///
  /// A shared future has one outcome, so letting a cancellable caller join one
  /// would mean a superseded search keystroke cancelling a request some other
  /// screen is waiting on. Those callers get their own flight; every one of
  /// them already passes a token precisely because it expects to be cancelled.
  Future<Response<dynamic>> _coalescedGet(
    String path,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  ) {
    if (cancelToken != null) {
      return dio.get<dynamic>(path, queryParameters: query, cancelToken: cancelToken);
    }

    final key = _requestKey(path, query);
    final pending = _inFlightGets[key];
    if (pending != null) return pending;

    final flight = dio.get<dynamic>(path, queryParameters: query).whenComplete(
      () {
        // A block body, and it has to be one. `whenComplete` awaits whatever
        // its callback returns, and `Map.remove` returns the value it removed —
        // which here is this very future. Written as `() => _inFlightGets
        // .remove(key)` the flight waits on itself and never completes, which
        // is a deadlock rather than a slow request: every caller of this path
        // hangs for good.
        _inFlightGets.remove(key);
      },
    );
    _inFlightGets[key] = flight;
    return flight;
  }

  /// Identity of a GET: the path plus its query in a stable order, so two
  /// callers that built the same map in a different order still collapse.
  static String _requestKey(String path, Map<String, dynamic>? query) {
    if (query == null || query.isEmpty) return path;
    final keys = query.keys.toList(growable: false)..sort();
    final buffer = StringBuffer(path);
    for (final key in keys) {
      buffer.write('|$key=${query[key]}');
    }
    return buffer.toString();
  }

  /// Drops any in-flight coalescing entries. For tests, and for a session
  /// change — a new token makes a flight started under the old one useless.
  static void resetInFlight() => _inFlightGets.clear();

  /// GET for the handful of endpoints that return a bare JSON array rather
  /// than an object — the `/contains` family (`/me/tracks/contains`,
  /// `/me/albums/contains`, `/me/following/contains`) and
  /// `/artists/{id}/top-tracks` on some responses.
  Future<List<T>> getArray<T>(
    String path,
    T Function(Object? element) parse, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    try {
      final response = await dio.get<dynamic>(
        path,
        queryParameters: _clean(query),
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is! List) return const [];
      return data.map(parse).toList(growable: false);
    } on DioException catch (error) {
      throw ErrorMapper.fromDio(error);
    } on Object catch (error, stackTrace) {
      throw ErrorMapper.fromUnknown(error, stackTrace);
    }
  }

  /// `/contains` endpoints return `[true, false, …]` aligned with the IDs sent.
  /// A `/contains`-style endpoint returning a positional array of booleans.
  ///
  /// Returns all-false rather than throwing when Spotify refuses the endpoint
  /// for this application, and remembers the refusal so the next screen does
  /// not pay for it again. All-false is the honest answer to "is this saved?"
  /// when the app is not allowed to ask: the heart renders unfilled instead of
  /// the list failing to render at all.
  Future<List<bool>> getBoolArray(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (isKnownUnavailable(path)) return const [];

    try {
      return await getArray<bool>(
        path,
        (element) => element is bool && element,
        query: query,
        cancelToken: cancelToken,
      );
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden ||
          error.kind == ApiFailureKind.notFound) {
        markUnavailable(path, error);
        return const [];
      }
      rethrow;
    }
  }

  /// Endpoints this app has already been refused, by path.
  ///
  /// Availability is decided per *application* by its quota mode, so a 403
  /// here is a permanent property of the build, not a transient failure. Once
  /// Spotify has said no, asking again cannot produce a different answer
  /// before the session changes.
  ///
  /// Endpoints known in advance to be unavailable are not routed through this
  /// — they were deleted outright. What is left is the case that can only be
  /// discovered at runtime: an endpoint that works for some applications and
  /// not this one. `/me/tracks/contains` is the live example — Spotify's
  /// February 2026 changes folded the per-entity `contains` endpoints into
  /// `/me/library/contains`, and the old paths now answer 403 to a Development
  /// Mode app. Every library screen calls one, so without this the same
  /// refusal is paid for on every scroll.
  /// The refusal is kept, not just the fact of it, so a cached failure can be
  /// replayed to callers that expect to catch one.
  static final Map<String, ApiException> _unavailablePaths =
      <String, ApiException>{};

  /// Forgets which optional endpoints were unavailable.
  ///
  /// Called when the session changes: a different account can be on a
  /// different app, and re-checking after a dashboard change is exactly what
  /// the access-denied screen's "check again" button is for.
  static void resetAvailability() {
    _unavailablePaths.clear();
    // A flight started under the previous token would resolve against the
    // previous account, so nothing may join one across a session change.
    resetInFlight();
  }

  /// True when [path] has already been refused in this session. Visible for
  /// testing.
  static bool isKnownUnavailable(String path) =>
      _unavailablePaths.containsKey(path);

  /// Records that Spotify refused [path] for this application.
  static void markUnavailable(String path, ApiException error) {
    if (error.kind != ApiFailureKind.forbidden &&
        error.kind != ApiFailureKind.notFound) {
      return;
    }
    if (_unavailablePaths.containsKey(path)) return;
    _unavailablePaths[path] = error;
    AppLogger.info(
      'Optional endpoint unavailable ($path → ${error.statusCode}); '
      'not asking again this session',
      scope: 'api',
    );
  }

  /// Re-throws the remembered refusal for [path], if there is one.
  ///
  /// Lets an endpoint that reports failure by throwing skip the round trip it
  /// already knows will fail, while its callers keep catching exactly what
  /// they caught before.
  static void throwIfKnownUnavailable(String path) {
    final remembered = _unavailablePaths[path];
    if (remembered != null) throw remembered;
  }

  /// Attempts a request that may not be available to this app, returning null
  /// instead of throwing on 403/404.
  ///
  /// Spotify restricted several endpoints in November 2024 so that apps
  /// created after that date receive 403, and removed more from Development
  /// Mode apps in February 2026. AURIX calls those endpoints optimistically —
  /// an app with extended quota gets the richer data — and falls back silently
  /// when it does not. That decision belongs here rather than in a dozen
  /// try/catch blocks.
  Future<T?> tryGet<T>(
    String path,
    T Function(Map<String, dynamic> json) parse, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) async {
    if (isKnownUnavailable(path)) return null;

    try {
      return await get<T>(path, parse, query: query, cancelToken: cancelToken);
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden ||
          error.kind == ApiFailureKind.notFound) {
        markUnavailable(path, error);
        return null;
      }
      rethrow;
    }
  }

  /// Drops null/empty query values so Spotify never sees `?market=`.
  Map<String, dynamic>? _clean(Map<String, dynamic>? query) {
    if (query == null) return null;
    final cleaned = <String, dynamic>{};
    query.forEach((key, value) {
      if (value == null) return;
      if (value is String && value.isEmpty) return;
      if (value is Iterable && value.isEmpty) return;
      cleaned[key] = value is Iterable ? value.join(',') : value;
    });
    return cleaned.isEmpty ? null : cleaned;
  }

  /// Clamps a page size to Spotify's documented maximum. Exceeding it is a
  /// 400, which would otherwise only show up for users with large libraries.
  static int clampLimit(int limit) =>
      limit.clamp(1, AppConstants.maxPageSize).toInt();

  /// Clamps a `/search` page size, which Spotify caps far lower than the rest.
  ///
  /// Separate from [clampLimit] because the two limits genuinely differ: 50
  /// everywhere else, 10 on search since February 2026. Sharing one clamp sent
  /// `limit=20` to `/search` and turned every query into a `400`.
  static int clampSearchLimit(int limit) =>
      limit.clamp(1, AppConstants.maxSearchPageSize).toInt();

  /// Spotify's batch endpoints (`/albums?ids=`, `/artists?ids=`) accept at
  /// most 20–50 IDs. Callers chunk through this.
  static List<List<T>> chunk<T>(List<T> items, int size) {
    if (items.isEmpty) return const [];
    final chunks = <List<T>>[];
    for (var i = 0; i < items.length; i += size) {
      chunks.add(items.sublist(i, (i + size).clamp(0, items.length)));
    }
    return chunks;
  }
}
