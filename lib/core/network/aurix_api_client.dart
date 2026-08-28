import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../data/services/api/aurix_session_store.dart';
import '../config/env.dart';
import '../constants/app_constants.dart';
import '../constants/aurix_endpoints.dart';
import '../utils/app_logger.dart';
import 'api_exception.dart';
import 'retry_interceptor.dart';

/// The HTTP client for AURIX's own backend.
///
/// Deliberately separate from [DioClient], which builds the Spotify clients.
/// The two must never be the same instance: that one attaches the user's
/// Spotify bearer token to everything it sends, and the AURIX API must never
/// receive it — the same reasoning that gives the lyrics and YouTube services
/// their own clients.
///
/// ## What this class is responsible for
///
///  * Attaching a valid access token to every request.
///  * Refreshing it exactly once when several requests find it expired at the
///    same moment, and replaying them.
///  * Turning the API's error envelope into an [AurixApiException] the UI can
///    branch on, so no `DioException` ever crosses into a repository.
///
/// ## What it is deliberately *not* responsible for
///
/// Deciding that a session is over. A refresh can fail because the token was
/// revoked or because the user walked into a tunnel, and only the first should
/// sign anyone out. So this raises [AurixSessionEnded] for a server refusal and
/// an ordinary network error otherwise, and [AurixSessionStore] acts on the
/// difference.
class AurixApiClient {
  AurixApiClient({required AurixSessionStore session, Dio? dio, String? baseUrl})
    : _session = session,
      _dio = dio ?? Dio(),
      _refreshDio = Dio() {
    final resolved = baseUrl ?? Env.apiBaseUrl;

    _dio.options = BaseOptions(
      baseUrl: resolved,
      connectTimeout: AppConstants.connectTimeout,
      receiveTimeout: AppConstants.receiveTimeout,
      sendTimeout: AppConstants.sendTimeout,
      responseType: ResponseType.json,
      headers: const {'Accept': 'application/json'},
      // 204 is a normal answer here — every write that returns nothing uses
      // it — so treating <400 as success keeps it out of the error path.
      validateStatus: (status) => status != null && status < 400,
    );

    // The refresh client is a *separate* Dio with no interceptors at all.
    // Sharing the main one would make a failing refresh recurse into itself:
    // the 401 handler would fire on the refresh request, which would attempt a
    // refresh, and so on until the stack ran out.
    _refreshDio.options = BaseOptions(
      baseUrl: resolved,
      connectTimeout: AppConstants.connectTimeout,
      receiveTimeout: AppConstants.receiveTimeout,
      responseType: ResponseType.json,
      headers: const {'Accept': 'application/json'},
      validateStatus: (status) => status != null && status < 400,
    );

    _dio.interceptors.addAll([
      _AuthInterceptor(this),
      RetryInterceptor(),
      if (kDebugMode) _LogInterceptor(),
    ]);
  }

  final AurixSessionStore _session;
  final Dio _dio;
  final Dio _refreshDio;

  Dio get dio => _dio;

  bool get isConfigured => _dio.options.baseUrl.isNotEmpty;

  // ---- Verbs -------------------------------------------------------------
  //
  // Thin wrappers that map the response body to a `Map` and every failure to
  // an [AurixApiException]. Services call these rather than Dio directly, so
  // there is one place that decides what an error looks like.

  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) => _send(() => _dio.get<dynamic>(path, queryParameters: query, cancelToken: cancelToken));

  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    CancelToken? cancelToken,
  }) => _send(
    () => _dio.post<dynamic>(
      path,
      data: body,
      queryParameters: query,
      cancelToken: cancelToken,
    ),
  );

  Future<Map<String, dynamic>> put(String path, {Object? body}) =>
      _send(() => _dio.put<dynamic>(path, data: body));

  Future<Map<String, dynamic>> patch(String path, {Object? body}) =>
      _send(() => _dio.patch<dynamic>(path, data: body));

  Future<Map<String, dynamic>> delete(String path, {Object? body}) =>
      _send(() => _dio.delete<dynamic>(path, data: body));

  /// A multipart upload — the logo, the icon and font files.
  Future<Map<String, dynamic>> upload(
    String path, {
    required List<int> bytes,
    required String filename,
    Map<String, String> fields = const {},
  }) {
    final form = FormData.fromMap(<String, dynamic>{
      ...fields,
      'file': MultipartFile.fromBytes(bytes, filename: filename),
    });
    return _send(() => _dio.post<dynamic>(path, data: form));
  }

  Future<Map<String, dynamic>> _send(Future<Response<dynamic>> Function() call) async {
    if (!isConfigured) {
      throw const AurixApiException(
        kind: ApiFailureKind.unknown,
        code: 'not_configured',
        message: 'AURIX is not connected to a server yet.',
      );
    }

    try {
      final response = await call();
      final data = response.data;
      if (data is Map<String, dynamic>) return data;
      // A 204, or a body that is not an object. Both are success; the caller
      // reads named keys and finds none, which is exactly right.
      return const <String, dynamic>{};
    } on DioException catch (error) {
      throw AurixApiException.from(error);
    }
  }

  // ---- Token plumbing ----------------------------------------------------

  /// A token that will still be valid when the request lands.
  Future<String?> _validToken() => _session.validAccessToken(_exchangeRefreshToken);

  /// Forces a refresh after a 401.
  Future<String?> _forceRefresh() => _session.refresh(_exchangeRefreshToken);

  /// The one call that turns a refresh token into a new pair.
  ///
  /// Raises [AurixSessionEnded] only for a 401/403 — a refusal — so that a
  /// timeout or a DNS failure leaves the session intact. Getting this
  /// distinction wrong is what makes an app sign people out on a train.
  Future<({String accessToken, String refreshToken, DateTime expiresAt})?>
  _exchangeRefreshToken(String refreshToken) async {
    try {
      final response = await _refreshDio.post<dynamic>(
        AurixEndpoints.refresh,
        data: <String, dynamic>{'refreshToken': refreshToken},
      );

      final data = response.data;
      if (data is! Map<String, dynamic>) throw const AurixSessionEnded();

      final access = data['accessToken'];
      final refresh = data['refreshToken'];
      if (access is! String || refresh is! String) throw const AurixSessionEnded();

      return (
        accessToken: access,
        refreshToken: refresh,
        expiresAt:
            DateTime.tryParse(data['expiresAt'] as String? ?? '') ??
            DateTime.now().add(const Duration(minutes: 25)),
      );
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      if (status == 401 || status == 403) throw const AurixSessionEnded();
      rethrow;
    }
  }

  void close() {
    _dio.close(force: true);
    _refreshDio.close(force: true);
  }
}

/// Attaches the bearer token, and refreshes once on a 401.
class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this._client);

  final AurixApiClient _client;

  /// Marks a request that has already been replayed after a refresh.
  static const String _retriedKey = 'aurix.auth_retried';

  /// Paths that must never carry a token or trigger a refresh.
  ///
  /// Sign-in and registration have no session yet by definition, and the theme
  /// read is deliberately public so the login screen can be painted before
  /// anyone has signed in. Attaching a stale token to those would turn a
  /// working request into a 401 and, worse, into a refresh attempt that signs
  /// the user out while they are trying to sign in.
  static const Set<String> _anonymous = <String>{
    AurixEndpoints.login,
    AurixEndpoints.register,
    AurixEndpoints.refresh,
    AurixEndpoints.forgotPassword,
    AurixEndpoints.resetPassword,
    AurixEndpoints.verifyEmail,
    AurixEndpoints.theme,
    AurixEndpoints.themeVersion,
    AurixEndpoints.health,

    // The other ways in. Each of these either has no session yet or is about
    // to create one, and every one of them is a request a *signed-out* user
    // makes — so a stale token attached here would turn a working sign-in into
    // a 401 and, worse, into a refresh that ends the session the user is in
    // the middle of replacing.
    AurixEndpoints.authMethods,
    AurixEndpoints.phoneVerify,
    AurixEndpoints.oauthExchange,
    AurixEndpoints.linkCode,
    AurixEndpoints.linkConfirm,
    AurixEndpoints.linkCancel,

    // Deliberately absent: `phoneStart` and the per-provider `oauthStart`.
    // Both are `optionalAuth` on the server and mean something *different*
    // when a token is present — "add this method to the account I am already
    // signed in to" rather than "sign me in". Listing them here would strip
    // the token and silently turn every link attempt into a second account,
    // which is the exact failure this whole feature exists to prevent.
    //
    // They are safe to leave out: with no session, `_validToken` finds no
    // refresh token, returns null without a network call, and the request goes
    // out unauthenticated.
  };

  bool _isAnonymous(String path) => _anonymous.contains(path);

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_isAnonymous(options.path)) return handler.next(options);

    final token = await _client._validToken();
    if (token != null) options.headers['Authorization'] = 'Bearer $token';
    handler.next(options);
  }

  @override
  Future<void> onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    final status = err.response?.statusCode;

    final shouldRefresh =
        status == 401 &&
        !_isAnonymous(options.path) &&
        options.extra[_retriedKey] != true;

    if (!shouldRefresh) return handler.next(err);

    final token = await _client._forceRefresh();
    if (token == null) return handler.next(err);

    // Replayed once, and marked so a second 401 on the retry falls straight
    // through. Without the mark a server that answers 401 for a non-token
    // reason would put this in a refresh loop.
    options.extra[_retriedKey] = true;
    options.headers['Authorization'] = 'Bearer $token';

    try {
      final response = await _client.dio.fetch<dynamic>(options);
      return handler.resolve(response);
    } on DioException catch (retryError) {
      return handler.next(retryError);
    }
  }
}

/// Debug-only request logging. Bodies are never logged — they carry the user's
/// library, and the auth responses carry credentials.
class _LogInterceptor extends Interceptor {
  static const String _startKey = 'aurix.request_start';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.extra[_startKey] = DateTime.now().millisecondsSinceEpoch;
    AppLogger.debug('→ ${options.method} ${options.path}', scope: 'api');
    handler.next(options);
  }

  @override
  void onResponse(Response<dynamic> response, ResponseInterceptorHandler handler) {
    AppLogger.debug(
      '← ${response.statusCode} ${response.requestOptions.path} '
      '(${_elapsed(response.requestOptions)}ms)',
      scope: 'api',
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    AppLogger.warn(
      '✗ ${err.response?.statusCode ?? err.type.name} '
      '${err.requestOptions.method} ${err.requestOptions.path} '
      '(${_elapsed(err.requestOptions)}ms)'
      '${AurixApiException.codeIn(err.response?.data) == null ? '' : ' — ${AurixApiException.codeIn(err.response?.data)}'}',
      scope: 'api',
    );
    handler.next(err);
  }

  int _elapsed(RequestOptions options) {
    final start = options.extra[_startKey];
    if (start is! int) return 0;
    return DateTime.now().millisecondsSinceEpoch - start;
  }
}

/// A failure from the AURIX API.
///
/// Extends [ApiException] so every existing `on ApiException` handler in the
/// app keeps working — the error mapper, the retry logic and the state views
/// were all written against it. What this adds is [code]: the API's stable
/// machine-readable string, which is what the auth screens branch on to turn
/// `email_in_use` into "an account already exists" rather than a generic
/// failure.
class AurixApiException extends ApiException {
  const AurixApiException({
    required super.kind,
    required super.message,
    this.code,
    super.statusCode,
    super.debugDetail,
    super.endpoint,
  });

  /// The API's error code — `invalid_credentials`, `email_in_use`,
  /// `admin_only`, `rate_limited`, and so on.
  final String? code;

  factory AurixApiException.from(DioException error) {
    final status = error.response?.statusCode;
    final code = codeIn(error.response?.data);
    final message = messageIn(error.response?.data);
    final endpoint = error.requestOptions.path;

    final kind = switch (error.type) {
      DioExceptionType.connectionTimeout ||
      DioExceptionType.receiveTimeout ||
      DioExceptionType.sendTimeout => ApiFailureKind.timeout,
      DioExceptionType.connectionError => ApiFailureKind.offline,
      DioExceptionType.cancel => ApiFailureKind.cancelled,
      // `?? 0` because a relational pattern cannot match a nullable receiver,
      // and a response with no status is not a 5xx — it falls to `unknown`,
      // which is where a bodyless transport failure belongs.
      _ => switch (status ?? 0) {
        401 => ApiFailureKind.unauthorized,
        403 => ApiFailureKind.forbidden,
        404 => ApiFailureKind.notFound,
        429 => ApiFailureKind.rateLimited,
        >= 500 => ApiFailureKind.serverError,
        _ => ApiFailureKind.unknown,
      },
    };

    return AurixApiException(
      kind: kind,
      code: code,
      statusCode: status,
      // The server writes its messages to be shown to a user — that is the
      // contract in `utils/errors.js` — so a message it supplied is used as-is.
      // Anything else gets a sentence written here, because a raw transport
      // error is not something to put in front of a person.
      message: message ?? _fallbackMessage(kind),
      debugDetail: error.message,
      endpoint: endpoint,
    );
  }

  static String _fallbackMessage(ApiFailureKind kind) => switch (kind) {
    ApiFailureKind.offline => 'AURIX cannot reach the server. Check your connection.',
    ApiFailureKind.timeout => 'That took too long. Try again.',
    ApiFailureKind.unauthorized => 'Sign in to continue.',
    ApiFailureKind.forbidden => 'You do not have access to that.',
    ApiFailureKind.notFound => 'That is no longer there.',
    ApiFailureKind.rateLimited => 'Too many attempts. Try again shortly.',
    ApiFailureKind.serverError => 'The server is having trouble. Try again shortly.',
    ApiFailureKind.cancelled => 'Cancelled.',
    _ => 'Something went wrong.',
  };

  /// Reads `error.code` out of the API's envelope.
  static String? codeIn(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is! Map) return null;
    final code = error['code'];
    return code is String && code.isNotEmpty ? code : null;
  }

  /// Reads `error.message` out of the API's envelope.
  static String? messageIn(Object? data) {
    if (data is! Map) return null;
    final error = data['error'];
    if (error is! Map) return null;
    final message = error['message'];
    return message is String && message.isNotEmpty ? message : null;
  }

  @override
  String toString() =>
      'AurixApiException($code, status: $statusCode, endpoint: $endpoint)';
}
