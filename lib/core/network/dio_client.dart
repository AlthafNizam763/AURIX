import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../constants/app_constants.dart';
import '../constants/spotify_endpoints.dart';
import '../utils/app_logger.dart';
import 'auth_interceptor.dart';
import 'retry_interceptor.dart';
import 'token_provider.dart';

/// Builds the configured [Dio] instances the app uses.
///
/// Two are needed and they are deliberately different:
///
///  * [buildApiClient] talks to `api.spotify.com` and carries a bearer token.
///  * [buildAuthClient] talks to `accounts.spotify.com`, must *not* carry a
///    bearer token, and must never be retried by the auth interceptor —
///    otherwise a failing token exchange would recurse into itself.
abstract final class DioClient {
  static Dio buildApiClient({
    required TokenProvider tokenProvider,
    void Function()? onSessionExpired,
  }) {
    final dio = Dio(
      BaseOptions(
        baseUrl: SpotifyEndpoints.apiBaseUrl,
        connectTimeout: AppConstants.connectTimeout,
        receiveTimeout: AppConstants.receiveTimeout,
        sendTimeout: AppConstants.sendTimeout,
        responseType: ResponseType.json,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        // Several Spotify player endpoints legitimately answer 204 with an
        // empty body; treating <400 as success keeps that out of the error
        // path so it can be handled as data.
        validateStatus: (status) => status != null && status < 400,
      ),
    );

    dio.interceptors.addAll([
      AuthInterceptor(tokenProvider, onSessionExpired: onSessionExpired),
      RetryInterceptor(),
      if (kDebugMode) _LogInterceptor(),
    ]);

    return dio;
  }

  /// Client for the OAuth token endpoint.
  static Dio buildAuthClient({String? proxyBaseUrl}) {
    final dio = Dio(
      BaseOptions(
        baseUrl: proxyBaseUrl?.isNotEmpty == true
            ? proxyBaseUrl!
            : SpotifyEndpoints.accountsBaseUrl,
        connectTimeout: AppConstants.connectTimeout,
        receiveTimeout: AppConstants.receiveTimeout,
        responseType: ResponseType.json,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        validateStatus: (status) => status != null && status < 400,
      ),
    );

    // Deliberately no AuthInterceptor. Retries are still safe: the token
    // endpoint is a POST, but a failed exchange never partially applied, and
    // RetryInterceptor only replays 429/5xx here.
    dio.interceptors.addAll([
      RetryInterceptor(maxRetries: 1),
      if (kDebugMode) _LogInterceptor(),
    ]);

    return dio;
  }
}

/// Debug-only request logging.
///
/// Bodies are never logged: Spotify responses contain the user's listening
/// history, and the token response contains credentials. Method, path, status
/// and duration are enough to debug with.
class _LogInterceptor extends Interceptor {
  static const String _startKey = 'aurix.request_start';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;
    AppLogger.debug('→ ${options.method} ${options.path}', scope: 'http');
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    AppLogger.debug(
      '← ${response.statusCode} ${response.requestOptions.path} '
      '(${_elapsed(response.requestOptions)}ms)',
      scope: 'http',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    // Spotify's own `error.message` is included because without it a failure
    // line names only a status code, and the two most common ones are
    // ambiguous: a 400 could be a malformed query or a `limit` above the cap
    // for this quota mode, and a 403 could be quota mode or a missing scope.
    // Spotify writes this string for the developer reading it — it echoes
    // neither the request nor the token.
    final reason = _spotifyMessage(err.response?.data);
    AppLogger.warn(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${err.requestOptions.method} ${err.requestOptions.path} '
      '(${_elapsed(err.requestOptions)}ms)'
      '${reason == null ? '' : ' — $reason'}',
      scope: 'http',
    );
    handler.next(err);
  }

  /// Pulls `error.message` out of either shape Spotify returns:
  /// `{"error": {"status", "message"}}` on the API host, and
  /// `{"error": "...", "error_description": "..."}` on the accounts host.
  static String? _spotifyMessage(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is Map) {
      final message = error['message'];
      return message is String && message.isNotEmpty ? message : null;
    }
    if (error is String) {
      final description = data['error_description'];
      return description is String && description.isNotEmpty
          ? description
          : error;
    }
    return null;
  }

  int _elapsed(RequestOptions options) {
    final start = options.extra[_startKey];
    if (start is! int) return 0;
    return DateTime.now().millisecondsSinceEpoch - start;
  }
}
