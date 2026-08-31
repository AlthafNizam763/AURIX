import 'dart:async';

import 'package:dio/dio.dart';

import '../utils/app_logger.dart';
import 'token_provider.dart';

/// Attaches the bearer token to every Spotify request and transparently
/// recovers from a 401 exactly once.
///
/// The single-flight guard matters more than it looks: the home screen fires
/// eight parallel requests, so an expired token produces eight simultaneous
/// 401s. Without coordination that is eight refresh calls racing each other,
/// seven of which invalidate the token the eighth just stored.
class AuthInterceptor extends QueuedInterceptor {
  AuthInterceptor(this._tokens, {this.onSessionExpired});

  final TokenProvider _tokens;

  /// Invoked when refresh fails for good. The app listens to route the user
  /// back to login.
  final void Function()? onSessionExpired;

  /// Marks requests that must not carry (or retry) auth — the token exchange
  /// itself, primarily.
  static const String skipAuthKey = 'aurix.skip_auth';
  static const String retriedKey = 'aurix.retried_after_401';

  Future<String?>? _refreshInFlight;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra[skipAuthKey] == true) {
      return handler.next(options);
    }

    final token = await _tokens.validAccessToken();
    if (token != null) {
      options.headers['Authorization'] = 'Bearer $token';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final options = err.requestOptions;
    final isUnauthorized = err.response?.statusCode == 401;
    final skipsAuth = options.extra[skipAuthKey] == true;
    final alreadyRetried = options.extra[retriedKey] == true;

    if (!isUnauthorized || skipsAuth || alreadyRetried) {
      return handler.next(err);
    }

    AppLogger.info('401 on ${options.path} — refreshing token', scope: 'auth');

    final token = await _refreshOnce();
    if (token == null) {
      onSessionExpired?.call();
      return handler.next(err);
    }

    try {
      final retried = await _retry(options, token);
      handler.resolve(retried);
    } on DioException catch (retryError) {
      handler.next(retryError);
    } on Object catch (retryError, stackTrace) {
      AppLogger.error(
        'Retry after refresh failed',
        scope: 'auth',
        error: retryError,
        stackTrace: stackTrace,
      );
      handler.next(err);
    }
  }

  /// Collapses concurrent refreshes into one network call whose result is
  /// shared by every waiting request.
  Future<String?> _refreshOnce() {
    final pending = _refreshInFlight;
    if (pending != null) return pending;

    final future = _tokens.forceRefresh().catchError((Object error) {
      AppLogger.warn('Token refresh threw', scope: 'auth', error: error);
      return null;
    }).whenComplete(() {
      _refreshInFlight = null;
    });

    _refreshInFlight = future;
    return future;
  }

  Future<Response<dynamic>> _retry(RequestOptions options, String token) {
    // A fresh Dio avoids re-entering this interceptor chain, which would let
    // a persistently-401ing endpoint loop forever.
    final dio = Dio(
      BaseOptions(
        baseUrl: options.baseUrl,
        connectTimeout: options.connectTimeout,
        receiveTimeout: options.receiveTimeout,
        sendTimeout: options.sendTimeout,
        responseType: options.responseType,
        validateStatus: options.validateStatus,
      ),
    );

    return dio.request<dynamic>(
      options.path,
      data: options.data,
      queryParameters: options.queryParameters,
      cancelToken: options.cancelToken,
      options: Options(
        method: options.method,
        headers: <String, dynamic>{
          ...options.headers,
          'Authorization': 'Bearer $token',
        },
        contentType: options.contentType,
        responseType: options.responseType,
        extra: <String, dynamic>{...options.extra, retriedKey: true},
      ),
    );
  }
}
