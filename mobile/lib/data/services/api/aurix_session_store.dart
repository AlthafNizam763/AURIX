import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../core/storage/secure_store.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/aurix_user.dart';

/// The signed-in session — tokens and the cached user record.
///
/// ## What replaced `FirebaseAuth.instance`
///
/// Firebase persisted the session itself: the SDK held the credential, refreshed
/// it, and published `authStateChanges()`. None of that exists now, so this
/// class is the whole of it — storage, expiry, the broadcast stream the router
/// and the auth controller listen to, and the single-flight refresh that keeps
/// a burst of parallel 401s from producing a burst of refresh calls.
///
/// ## Where the tokens live
///
/// In [SecureStore] — the Android Keystore and the iOS Keychain — and nowhere
/// else. Never in SharedPreferences, never in a file, never in a log line. This
/// is the same rule the Spotify tokens already followed, and it matters more
/// here: an AURIX refresh token is a 60-day key to the user's whole library.
///
/// The cached [AurixUser] is stored beside them rather than in preferences for
/// one specific reason: it is what lets the splash screen render the right
/// account before the first network call returns, and it holds an email
/// address.
class AurixSessionStore {
  AurixSessionStore({required SecureStore store}) : _store = store;

  final SecureStore _store;

  static const String _accessKey = 'aurix_access_token';
  static const String _refreshKey = 'aurix_refresh_token';
  static const String _expiryKey = 'aurix_token_expiry';
  static const String _userKey = 'aurix_user';

  /// Refresh this long before the access token actually expires.
  ///
  /// Without a margin every long-running screen races the clock: a request
  /// begun at T-1s arrives after expiry and comes back 401, which works but
  /// costs a retry. Sixty seconds is comfortably longer than any request here.
  static const Duration _refreshMargin = Duration(seconds: 60);

  String? _accessToken;
  String? _refreshToken;
  DateTime? _expiresAt;
  AurixUser? _user;
  bool _loaded = false;

  /// In-flight refresh, so twenty simultaneous 401s produce one refresh call.
  Future<String?>? _refreshInFlight;

  final StreamController<AurixUser?> _changes =
      StreamController<AurixUser?>.broadcast();

  /// Emits on every sign-in, sign-out and profile change.
  ///
  /// The replacement for `FirebaseAuth.authStateChanges()`, and it has the same
  /// contract: it emits the current value to a new listener, so a widget that
  /// subscribes after sign-in does not sit on `null` waiting for a change that
  /// already happened.
  Stream<AurixUser?> changes() async* {
    await _ensureLoaded();
    yield _user;
    yield* _changes.stream;
  }

  AurixUser? get currentUser => _user;

  String? get uid => _user?.uid;

  bool get isSignedIn => _user != null && _refreshToken != null;

  /// Reads the persisted session. Cheap after the first call.
  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;

    try {
      _accessToken = await _store.read(_accessKey);
      _refreshToken = await _store.read(_refreshKey);

      final expiry = await _store.read(_expiryKey);
      _expiresAt = expiry == null ? null : DateTime.tryParse(expiry);

      final userJson = await _store.read(_userKey);
      if (userJson != null) {
        final decoded = jsonDecode(userJson);
        if (decoded is Map<String, dynamic>) {
          _user = AurixUser.fromDocument(decoded['uid'] as String? ?? '', decoded);
        }
      }
    } on Object catch (error) {
      // A corrupt entry — common after a restore-from-backup — must sign the
      // user out, not crash the app on launch.
      AppLogger.warn('Could not restore the session', scope: 'auth', error: error);
      _accessToken = null;
      _refreshToken = null;
      _expiresAt = null;
      _user = null;
    }
  }

  /// Called during `bootstrap()`, so the first frame knows whether anyone is
  /// signed in without an await inside a build method.
  Future<void> restore() => _ensureLoaded();

  /// Stores a fresh session and announces it.
  Future<void> save({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
    required AurixUser user,
  }) async {
    _loaded = true;
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _expiresAt = expiresAt;
    _user = user;

    await Future.wait([
      _store.write(_accessKey, accessToken),
      _store.write(_refreshKey, refreshToken),
      _store.write(_expiryKey, expiresAt.toIso8601String()),
      _store.write(_userKey, jsonEncode(user.toDocument()..['uid'] = user.uid)),
    ]);

    _changes.add(_user);
  }

  /// Replaces the tokens without touching the cached profile. Used by refresh.
  Future<void> saveTokens({
    required String accessToken,
    required String refreshToken,
    required DateTime expiresAt,
  }) async {
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _expiresAt = expiresAt;

    await Future.wait([
      _store.write(_accessKey, accessToken),
      _store.write(_refreshKey, refreshToken),
      _store.write(_expiryKey, expiresAt.toIso8601String()),
    ]);
  }

  /// Updates the cached profile after a rename or an avatar change.
  Future<void> saveUser(AurixUser user) async {
    _user = user;
    await _store.write(_userKey, jsonEncode(user.toDocument()..['uid'] = user.uid));
    _changes.add(_user);
  }

  Future<void> clear() async {
    _loaded = true;
    _accessToken = null;
    _refreshToken = null;
    _expiresAt = null;
    _user = null;
    _refreshInFlight = null;

    await Future.wait([
      _store.delete(_accessKey),
      _store.delete(_refreshKey),
      _store.delete(_expiryKey),
      _store.delete(_userKey),
    ]);

    _changes.add(null);
  }

  /// The refresh token, for the sign-out call that revokes it server-side.
  Future<String?> readRefreshToken() async {
    await _ensureLoaded();
    return _refreshToken;
  }

  /// A token that will still be valid when the request lands, or null.
  ///
  /// [onRefresh] is supplied by the client rather than held here so this class
  /// has no Dio dependency — the same separation `TokenProvider` draws for the
  /// Spotify side, and what keeps the two from being circular.
  Future<String?> validAccessToken(
    Future<
      ({String accessToken, String refreshToken, DateTime expiresAt})?
    >
    Function(String refreshToken) onRefresh,
  ) async {
    await _ensureLoaded();

    final token = _accessToken;
    final expiry = _expiresAt;

    if (token != null &&
        expiry != null &&
        DateTime.now().isBefore(expiry.subtract(_refreshMargin))) {
      return token;
    }

    return refresh(onRefresh);
  }

  /// Exchanges the refresh token for a new pair. Single-flight.
  Future<String?> refresh(
    Future<
      ({String accessToken, String refreshToken, DateTime expiresAt})?
    >
    Function(String refreshToken) onRefresh,
  ) {
    // Every caller awaits the same future. Without this, a screen firing six
    // parallel requests on a cold start would send six refreshes — and because
    // the server *rotates* the token on use, five of them would present a token
    // the first had already spent and be told the session ended.
    return _refreshInFlight ??= _doRefresh(onRefresh).whenComplete(() {
      _refreshInFlight = null;
    });
  }

  Future<String?> _doRefresh(
    Future<
      ({String accessToken, String refreshToken, DateTime expiresAt})?
    >
    Function(String refreshToken) onRefresh,
  ) async {
    await _ensureLoaded();

    final refreshToken = _refreshToken;
    if (refreshToken == null) return null;

    try {
      final result = await onRefresh(refreshToken);
      if (result == null) {
        await clear();
        return null;
      }

      await saveTokens(
        accessToken: result.accessToken,
        refreshToken: result.refreshToken,
        expiresAt: result.expiresAt,
      );
      return result.accessToken;
    } on Object catch (error) {
      // A refresh that fails because the *network* is down must not sign the
      // user out — they would be logged out by a lift ride. Only a refusal
      // from the server ends the session, and the client raises
      // [AurixSessionEnded] for exactly that case.
      if (error is AurixSessionEnded) {
        AppLogger.info('Session ended by the server; signing out', scope: 'auth');
        await clear();
        return null;
      }
      AppLogger.warn('Token refresh failed; keeping the session', scope: 'auth', error: error);
      return null;
    }
  }

  @visibleForTesting
  void debugSetUser(AurixUser? user) {
    _loaded = true;
    _user = user;
    _changes.add(user);
  }

  void dispose() {
    unawaited(_changes.close());
  }
}

/// Raised when the server refuses a refresh token outright.
///
/// Distinct from a network failure, and the distinction is the whole point: one
/// means "sign the user out", the other means "try again in a moment". Merging
/// them produces an app that logs people out when they walk into a tunnel.
class AurixSessionEnded implements Exception {
  const AurixSessionEnded([this.message = 'That session has ended.']);
  final String message;

  @override
  String toString() => 'AurixSessionEnded: $message';
}
