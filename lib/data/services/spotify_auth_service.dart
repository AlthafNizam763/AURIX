import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../core/config/env.dart';
import '../../core/constants/app_constants.dart';
import '../../core/constants/spotify_endpoints.dart';
import '../../core/constants/spotify_scopes.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/auth_interceptor.dart';
import '../../core/network/error_mapper.dart';
import '../../core/network/token_provider.dart';
import '../../core/storage/secure_store.dart';
import '../../core/utils/app_logger.dart';
import '../models/auth_session.dart';
import 'pkce.dart';

/// Raised when the user dismisses the Spotify login page. Not an error
/// condition — the UI returns to the login screen without a message.
class AuthCancelledException implements Exception {
  const AuthCancelledException();
}

/// Raised when the OAuth flow fails in a way worth telling the user about.
class AuthFailedException implements Exception {
  const AuthFailedException(this.message, {this.debugDetail});
  final String message;
  final String? debugDetail;

  @override
  String toString() => 'AuthFailedException($message${debugDetail == null ? '' : ': $debugDetail'})';
}

/// Spotify OAuth, using the Authorization Code flow with PKCE.
///
/// ## Why PKCE and not the client-credentials or implicit flows
///
/// * **Client credentials** cannot act on behalf of a user at all — no
///   library, no playback, no profile. It is also the flow that requires a
///   client secret, which cannot be protected inside a distributed APK.
/// * **Implicit grant** is deprecated by Spotify and returns no refresh token,
///   so the user would be thrown back to a login screen every hour.
/// * **Authorization Code + PKCE** is what Spotify documents for mobile
///   clients: no secret, and a refresh token for silent session renewal.
///
/// There is consequently no client secret anywhere in this app, and no backend
/// is required. (`AUTH_PROXY_BASE_URL` exists for deployments that want token
/// exchange to happen server-side anyway; it is optional and off by default.)
class SpotifyAuthService implements TokenProvider {
  SpotifyAuthService({
    required SecureStore secureStore,
    Dio? authClient,
    Future<String> Function({
      required String url,
      required String callbackUrlScheme,
    })? authenticate,
  }) : _store = secureStore,
       _dio = authClient ?? _defaultClient(),
       _authenticate = authenticate ?? _defaultAuthenticate;

  final SecureStore _store;
  final Dio _dio;
  final Future<String> Function({
    required String url,
    required String callbackUrlScheme,
  }) _authenticate;

  AuthSession? _session;

  /// Broadcasts session changes so the router can react to a logout that
  /// originated deep in the network layer.
  final StreamController<AuthSession?> _sessionChanges =
      StreamController<AuthSession?>.broadcast();

  Stream<AuthSession?> get onSessionChanged => _sessionChanges.stream;

  AuthSession? get session => _session;
  bool get isAuthenticated => _session?.isValid ?? false;

  static Dio _defaultClient() =>
      Dio(BaseOptions(
        baseUrl: Env.usesAuthProxy ? Env.authProxyBaseUrl : SpotifyEndpoints.accountsBaseUrl,
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        validateStatus: (status) => status != null && status < 400,
      ));

  /// How long to wait for the browser round trip before giving up.
  ///
  /// Only web and desktop honour this — on Android and iOS the session ends
  /// when the user dismisses the browser, and there is nothing to time out.
  /// Long enough for a password manager, a 2FA code and a slow page; short
  /// enough that a redirect URI Spotify refuses to honour does not leave the
  /// button spinning indefinitely.
  static const int _authTimeoutSeconds = 300;

  static Future<String> _defaultAuthenticate({
    required String url,
    required String callbackUrlScheme,
  }) => FlutterWebAuth2.authenticate(
    url: url,
    callbackUrlScheme: callbackUrlScheme,
    options: FlutterWebAuth2Options(
      // Keep the system browser's cookie jar out of the app so "log in as a
      // different account" actually works, and so the session cannot be
      // silently reused. Native-only; ignored on web.
      preferEphemeral: true,
      timeout: _authTimeoutSeconds,
      // Web only. The plugin discards any postMessage whose origin is not this
      // value, defaulting to the origin the app itself is served from. That
      // default is wrong in the common local setup: `flutter run -d chrome`
      // serves on `localhost`, while Spotify insists the redirect URI use the
      // literal `127.0.0.1` — so the callback arrives from a origin the
      // plugin would otherwise ignore, and sign-in hangs with no error.
      //
      // Naming the redirect URI's own origin is correct either way: when the
      // app *is* served from 127.0.0.1 this resolves to the same string the
      // default would have produced.
      debugOrigin: kIsWeb && Env.webRedirectOrigin.isNotEmpty
          ? Env.webRedirectOrigin
          : null,
    ),
  );

  // -----------------------------------------------------------------------
  // Session lifecycle
  // -----------------------------------------------------------------------

  /// Rehydrates a session from secure storage at startup.
  ///
  /// An expired access token is not a failure: as long as a refresh token
  /// survived, the session is silently renewed and the user never sees a
  /// login screen.
  Future<AuthSession?> restoreSession() async {
    final accessToken = await _store.read(SecureKeys.accessToken);
    final refreshToken = await _store.read(SecureKeys.refreshToken);
    final expiresAtRaw = await _store.read(SecureKeys.expiresAt);
    final scopesRaw = await _store.read(SecureKeys.scopes);

    if (accessToken == null || accessToken.isEmpty) {
      // No access token but a refresh token survives — e.g. the app was
      // killed mid-refresh. Renew rather than discarding the login.
      if (refreshToken != null && refreshToken.isNotEmpty) {
        AppLogger.info('Restoring via refresh token only', scope: 'auth');
        return _refresh(refreshToken);
      }
      return null;
    }

    final expiresAt = DateTime.tryParse(expiresAtRaw ?? '');
    if (expiresAt == null) {
      await clearSession();
      return null;
    }

    final restored = AuthSession(
      accessToken: accessToken,
      expiresAt: expiresAt,
      refreshToken: refreshToken,
      scopes: (scopesRaw ?? '').split(' ').where((s) => s.isNotEmpty).toList(),
    );

    _session = restored;

    if (restored.needsRefresh && restored.canRefresh) {
      AppLogger.info('Restored session needs refresh', scope: 'auth');
      final refreshed = await _refresh(restored.refreshToken!);
      if (refreshed != null) return refreshed;
      // Refresh failed but the current token may still have life in it —
      // fall through and let the 401 interceptor deal with it if not.
      if (restored.isExpired) {
        await clearSession();
        return null;
      }
    }

    _emit(restored);
    AppLogger.info(
      'Session restored (${AppLogger.redactToken(accessToken)}, '
      '${restored.timeRemaining.inMinutes}m left)',
      scope: 'auth',
    );
    return restored;
  }

  /// Runs the interactive login.
  ///
  /// Throws [AuthCancelledException] if the user backs out, or
  /// [AuthFailedException] with a display-ready message otherwise.
  Future<AuthSession> login() async {
    if (!Env.isSpotifyConfigured) {
      // Spotify configuration, not AURIX's. This used to check 
      // — which meant "the app is configured" back when a Spotify Client ID was
      // what the app could not start without. It gates one optional feature now.
      throw AuthFailedException(
        'Spotify import is not configured in this build.',
        debugDetail: Env.spotifyConfigurationHint,
      );
    }

    final pkce = Pkce.generate();
    final state = Pkce.generateState();

    // Persisted so an OS-killed app (common on Android when the browser takes
    // the foreground) can still complete the exchange on relaunch.
    await _store.write(SecureKeys.codeVerifier, pkce.verifier);

    final authorizeUrl = Uri.parse(SpotifyEndpoints.authorize).replace(
      queryParameters: <String, String>{
        'client_id': Env.spotifyClientId,
        'response_type': 'code',
        'redirect_uri': Env.spotifyRedirectUri,
        'code_challenge_method': PkcePair.method,
        'code_challenge': pkce.challenge,
        'state': state,
        'scope': SpotifyScopes.asParameter,
        // Always show the consent screen so account switching is possible.
        'show_dialog': 'true',
      },
    );

    final String rawResult;
    try {
      rawResult = await _authenticate(
        url: authorizeUrl.toString(),
        callbackUrlScheme: Env.spotifyCallbackScheme,
      );
    } on Object catch (error) {
      await _store.delete(SecureKeys.codeVerifier);
      final text = error.toString().toLowerCase();

      // flutter_web_auth_2 throws PlatformException on user cancel. Treating
      // that as an error would show a scary message for a deliberate action.
      if (text.contains('cancel') || text.contains('canceled') || text.contains('cancelled')) {
        throw const AuthCancelledException();
      }

      // The browser opened but nothing ever came back. On web and desktop that
      // is exactly what a redirect URI Spotify does not recognise looks like:
      // the authorize page renders "INVALID_CLIENT: Invalid redirect URI" and
      // never redirects, so the plugin waits out its timeout. Naming the
      // suspect here saves the long "but the login page loaded fine" hunt.
      if (text.contains('timeout') || text.contains('timed out')) {
        AppLogger.error(
          'Authorization timed out with no redirect — the redirect URI is '
          'very likely not registered. ${Env.redirectUriRegistrationHint}',
          scope: 'auth',
          error: error,
        );
        throw AuthFailedException(
          'Spotify never returned to ${AppConstants.appName}. Check that this '
          'exact Redirect URI is registered in your Spotify app: '
          '${Env.spotifyRedirectUri}',
          debugDetail: error.toString(),
        );
      }

      AppLogger.error('Authorization failed', scope: 'auth', error: error);
      throw AuthFailedException(
        "Couldn't open the Spotify sign-in page.",
        debugDetail: error.toString(),
      );
    }

    // The plugin hands back whatever the browser landed on. A malformed value
    // must not escape as an unhandled FormatException — the repository only
    // catches the two auth exceptions, so anything else would surface as a
    // crash rather than a failed sign-in.
    final Uri callback;
    try {
      callback = Uri.parse(rawResult);
    } on FormatException catch (error) {
      await _store.delete(SecureKeys.codeVerifier);
      AppLogger.error('Callback was not a URL', scope: 'auth', error: error);
      throw AuthFailedException(
        'Spotify returned an unreadable response. Please try again.',
        debugDetail: 'Unparseable callback: ${error.message}',
      );
    }

    // Spotify puts the result in the query string; tolerate a fragment too,
    // which is what some providers (and the plugin's Apple path) hand back.
    final params = <String, String>{
      ...callback.queryParameters,
      if (callback.hasFragment)
        ...Uri.splitQueryString(callback.fragment),
    };

    final returnedState = params['state'];
    final errorParam = params['error'];
    final code = params['code'];

    if (errorParam != null) {
      await _store.delete(SecureKeys.codeVerifier);

      // `access_denied` is what Spotify sends when the consent screen is
      // dismissed with "Cancel" — a deliberate action, not a fault. It is also
      // what a Development Mode app returns for an account that is not on its
      // allowlist, and the two are indistinguishable here. Treating it as a
      // cancellation is the right default: the allowlist case is caught
      // unambiguously later, by the 403 on GET /me that drives
      // AccessDeniedScreen.
      if (errorParam == 'access_denied') {
        AppLogger.info(
          'Authorization returned access_denied — user cancelled, or this '
          'account is not on the app\'s Development Mode user list',
          scope: 'auth',
        );
        throw const AuthCancelledException();
      }

      AppLogger.error(
        'Authorization rejected: $errorParam',
        scope: 'auth',
        error: params['error_description'],
      );
      throw AuthFailedException(
        _authorizeErrorMessage(errorParam),
        debugDetail: params['error_description'] ?? errorParam,
      );
    }

    // A mismatched state means the redirect did not originate from the request
    // we started. Abort — do not exchange the code.
    if (returnedState != state) {
      await _store.delete(SecureKeys.codeVerifier);
      throw const AuthFailedException(
        'Sign-in could not be verified. Please try again.',
        debugDetail: 'OAuth state mismatch',
      );
    }

    if (code == null || code.isEmpty) {
      await _store.delete(SecureKeys.codeVerifier);
      throw const AuthFailedException(
        'Spotify did not return an authorization code.',
      );
    }

    final session = await _exchangeCode(code, pkce.verifier);
    await _store.delete(SecureKeys.codeVerifier);
    return session;
  }

  /// Turns an OAuth `error` code from the authorize redirect into something a
  /// person can act on.
  ///
  /// These are the codes RFC 6749 §4.1.2.1 defines plus the ones Spotify
  /// actually emits. Each one has a different fix, and the generic "sign-in
  /// failed" they used to share sent people to check the wrong things.
  /// `access_denied` is handled by the caller and deliberately absent here.
  static String _authorizeErrorMessage(String code) {
    switch (code) {
      case 'invalid_client':
      case 'unauthorized_client':
        // Wrong Client ID, or an app that has been deleted or suspended.
        return 'Spotify did not recognise this app. Check that '
            'SPOTIFY_CLIENT_ID matches an app in your Spotify dashboard.';

      case 'invalid_request':
        // In practice this is nearly always the redirect URI.
        return 'Spotify rejected the sign-in request. Check that this exact '
            'Redirect URI is registered in your Spotify app: '
            '${Env.spotifyRedirectUri}';

      case 'invalid_scope':
        return '${AppConstants.appName} asked for a permission Spotify would '
            'not grant. Update the app, or remove the unsupported scope.';

      case 'unsupported_response_type':
        return 'Spotify does not support this sign-in method for your app.';

      case 'server_error':
      case 'temporarily_unavailable':
        return 'Spotify is having trouble signing you in right now. '
            'Please try again shortly.';

      default:
        return 'Spotify declined the sign-in request. Please try again.';
    }
  }

  Future<AuthSession> _exchangeCode(String code, String verifier) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        Env.usesAuthProxy ? '/token' : '/api/token',
        data: <String, String>{
          'grant_type': 'authorization_code',
          'code': code,
          'redirect_uri': Env.spotifyRedirectUri,
          'client_id': Env.spotifyClientId,
          'code_verifier': verifier,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          extra: const {AuthInterceptor.skipAuthKey: true},
        ),
      );

      final body = response.data;
      if (body == null) {
        throw const AuthFailedException('Spotify returned an empty token response.');
      }

      final session = AuthSession.fromTokenResponse(body);
      if (session.accessToken.isEmpty) {
        throw const AuthFailedException('Spotify returned no access token.');
      }

      await _persist(session);
      AppLogger.info('Login complete, ${session.scopes.length} scopes granted', scope: 'auth');
      return session;
    } on DioException catch (error) {
      final mapped = ErrorMapper.fromDio(error);
      AppLogger.error('Token exchange failed', scope: 'auth', error: mapped);
      throw AuthFailedException(
        _exchangeErrorMessage(mapped),
        debugDetail: mapped.debugDetail,
      );
    } on AuthFailedException {
      rethrow;
    } on Object catch (error, stackTrace) {
      // A malformed token body reaches here as a FormatException or TypeError
      // out of AuthSession.fromTokenResponse. Left uncaught it would escape
      // the repository's `on AuthFailedException` and crash the sign-in.
      AppLogger.error(
        'Token response could not be read',
        scope: 'auth',
        error: error,
        stackTrace: stackTrace,
      );
      throw AuthFailedException(
        'Spotify sent a sign-in response ${AppConstants.appName} could not '
        'read. Please try again.',
        debugDetail: error.toString(),
      );
    }
  }

  /// What to tell the user when `/api/token` refuses the exchange.
  static String _exchangeErrorMessage(ApiException mapped) {
    // 400 here is overwhelmingly a redirect URI that does not match the
    // dashboard entry character for character. Print the exact string this
    // build sent, so it can be compared against the dashboard directly.
    if (mapped.statusCode == 400) {
      return 'Sign-in failed. Check that this exact Redirect URI is '
          'registered in your Spotify app: ${Env.spotifyRedirectUri}';
    }

    // On web the token call is a cross-origin request. A connection error with
    // no status is what a blocked one looks like from Dart — most often an
    // AUTH_PROXY_BASE_URL that does not send CORS headers, since
    // accounts.spotify.com itself allows the PKCE exchange from a browser.
    if (kIsWeb && mapped.kind == ApiFailureKind.offline && Env.usesAuthProxy) {
      return 'Could not reach the token endpoint from the browser. Check that '
          '${Env.authProxyBaseUrl} allows cross-origin requests, or clear '
          'AUTH_PROXY_BASE_URL to talk to Spotify directly.';
    }

    return mapped.message;
  }

  // -----------------------------------------------------------------------
  // TokenProvider
  // -----------------------------------------------------------------------

  @override
  Future<String?> validAccessToken() async {
    final current = _session;
    if (current == null) return null;
    if (!current.needsRefresh) return current.accessToken;
    if (!current.canRefresh) return current.isValid ? current.accessToken : null;

    final refreshed = await _refresh(current.refreshToken!);
    return refreshed?.accessToken ?? (current.isValid ? current.accessToken : null);
  }

  @override
  Future<String?> forceRefresh() async {
    final refreshToken =
        _session?.refreshToken ?? await _store.read(SecureKeys.refreshToken);
    if (refreshToken == null || refreshToken.isEmpty) {
      await clearSession();
      return null;
    }
    final refreshed = await _refresh(refreshToken);
    return refreshed?.accessToken;
  }

  @override
  Future<void> invalidateSession() => clearSession();

  Future<AuthSession?> _refresh(String refreshToken) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        Env.usesAuthProxy ? '/refresh' : '/api/token',
        data: <String, String>{
          'grant_type': 'refresh_token',
          'refresh_token': refreshToken,
          'client_id': Env.spotifyClientId,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          extra: const {AuthInterceptor.skipAuthKey: true},
        ),
      );

      final body = response.data;
      if (body == null) return null;

      // Spotify rotates refresh tokens: the response may carry a new one, and
      // may omit it to mean "keep the old one". Both cases must be handled or
      // the session dies at the next refresh.
      final session = AuthSession.fromTokenResponse(
        body,
        previousRefreshToken: refreshToken,
      );
      if (session.accessToken.isEmpty) return null;

      await _persist(session);
      AppLogger.info('Token refreshed', scope: 'auth');
      return session;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      // 400/401 from the token endpoint means the refresh token is dead —
      // revoked, or the user removed the app's access. The session is over.
      if (status == 400 || status == 401) {
        AppLogger.warn('Refresh token rejected — clearing session', scope: 'auth');
        await clearSession();
        return null;
      }
      // Anything else (offline, 5xx) is transient. Keep the session so the
      // user is not logged out by a flaky connection.
      AppLogger.warn('Refresh failed transiently', scope: 'auth', error: error.message);
      return null;
    }
  }

  // -----------------------------------------------------------------------
  // Persistence
  // -----------------------------------------------------------------------

  Future<void> _persist(AuthSession session) async {
    _session = session;
    await _store.write(SecureKeys.accessToken, session.accessToken);
    await _store.write(SecureKeys.expiresAt, session.expiresAt.toIso8601String());
    await _store.write(SecureKeys.scopes, session.scopes.join(' '));
    if (session.refreshToken != null) {
      await _store.write(SecureKeys.refreshToken, session.refreshToken);
    }
    _emit(session);
  }

  /// Logs out.
  ///
  /// Spotify has no token-revocation endpoint for PKCE clients, so "log out"
  /// means destroying the local credentials. The ephemeral browser session
  /// used at login means nothing is left behind in the system browser either.
  Future<void> clearSession() async {
    _session = null;
    await _store.delete(SecureKeys.accessToken);
    await _store.delete(SecureKeys.refreshToken);
    await _store.delete(SecureKeys.expiresAt);
    await _store.delete(SecureKeys.scopes);
    await _store.delete(SecureKeys.codeVerifier);
    _emit(null);
    AppLogger.info('Session cleared', scope: 'auth');
  }

  void _emit(AuthSession? session) {
    if (_sessionChanges.isClosed) return;
    _sessionChanges.add(session);
  }

  /// True when the granted token actually carries [scope]. Used to disable a
  /// control up front rather than letting it fail with a 403.
  bool hasScope(String scope) => _session?.hasScope(scope) ?? false;

  Future<void> dispose() async {
    await _sessionChanges.close();
  }
}

/// Thrown when a required OAuth scope was not granted.
extension AuthScopeGuard on SpotifyAuthService {
  void requireScope(String scope, String action) {
    if (hasScope(scope)) return;
    throw ApiException(
      kind: ApiFailureKind.forbidden,
      message: 'AURIX was not granted permission to $action. Sign in again to fix this.',
      reason: 'MISSING_SCOPE',
      debugDetail: 'Missing scope: $scope',
    );
  }
}
