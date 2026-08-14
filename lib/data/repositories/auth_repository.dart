import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/storage/metadata_cache.dart';
import '../../core/storage/preferences_store.dart';
import '../../core/utils/app_logger.dart';
import '../models/auth_session.dart';
import '../models/user_profile.dart';
import '../services/spotify_api_service.dart';
import '../services/spotify_auth_service.dart';
import '../services/spotify_user_service.dart';

/// What the app knows about the current session.
enum AuthStatus {
  unknown,
  unconfigured,
  signedOut,
  signedIn,

  /// Signed in with a valid token, but Spotify refuses every request for this
  /// account. Distinct from [signedOut] because signing in again will not help
  /// — the fix is in the Spotify developer dashboard, not in the app.
  accessDenied,
}

/// What Spotify's own `403` body points at.
///
/// Only causes that Spotify names in the response are listed. Anything else is
/// [unspecified] rather than guessed at — a confident wrong diagnosis sends
/// someone to the wrong dashboard page for an hour.
enum AccessDenialCause {
  /// "User not registered in the Developer Dashboard" — the application is in
  /// Development Mode and this account is not on its User Management list.
  userNotRegistered,

  /// The token is missing a scope the endpoint needs. Unlike the others, a
  /// fresh sign-in (re-consent) genuinely fixes this one.
  insufficientScope,

  /// Spotify refused without saying why. In practice this is nearly always the
  /// application not having declared the Web API in its dashboard settings.
  unspecified,
}

/// The evidence behind [AuthStatus.accessDenied].
///
/// Carried into the UI verbatim. The screen used to state two likely causes
/// and show nothing about the actual response, which left no way to tell which
/// one applied — or whether Spotify had said something else entirely.
class AccessDenial {
  const AccessDenial({
    required this.cause,
    this.statusCode,
    this.spotifyMessage,
    this.endpoint,
  });

  final AccessDenialCause cause;
  final int? statusCode;

  /// Spotify's `error.message`, untouched. Null when the body carried none.
  final String? spotifyMessage;

  final String? endpoint;

  factory AccessDenial.fromApiException(ApiException error) {
    final text = (error.apiMessage ?? '').toLowerCase();

    final cause = switch (text) {
      _ when text.contains('not registered in the developer dashboard') =>
        AccessDenialCause.userNotRegistered,
      _ when text.contains('insufficient client scope') || text.contains('scope') =>
        AccessDenialCause.insufficientScope,
      _ when error.reason == 'MISSING_SCOPE' => AccessDenialCause.insufficientScope,
      _ => AccessDenialCause.unspecified,
    };

    return AccessDenial(
      cause: cause,
      statusCode: error.statusCode,
      spotifyMessage: error.apiMessage,
      endpoint: error.endpoint,
    );
  }

  /// Whether re-running the OAuth flow could plausibly help. Only true for a
  /// scope problem — for the others it just burns the user's time.
  bool get isFixableBySigningInAgain => cause == AccessDenialCause.insufficientScope;

  /// One line for the log and the bug report.
  String get summary =>
      '${statusCode ?? 403} on ${endpoint ?? '/me'} — ${cause.name}'
      '${spotifyMessage == null ? '' : ': "$spotifyMessage"'}';
}

class AuthState {
  const AuthState({
    required this.status,
    this.session,
    this.profile,
    this.errorMessage,
    this.denial,
  });

  final AuthStatus status;
  final AuthSession? session;
  final UserProfile? profile;

  /// Display-ready message from the last failed sign-in attempt.
  final String? errorMessage;

  /// What Spotify said when it refused this account. Non-null only while
  /// [status] is [AuthStatus.accessDenied].
  final AccessDenial? denial;

  static const AuthState unknown = AuthState(status: AuthStatus.unknown);
  static const AuthState signedOut = AuthState(status: AuthStatus.signedOut);

  bool get isSignedIn => status == AuthStatus.signedIn;
  bool get isAccessDenied => status == AuthStatus.accessDenied;
  bool get hasPremium => profile?.hasPremium ?? false;

  AuthState copyWith({
    AuthStatus? status,
    AuthSession? session,
    UserProfile? profile,
    String? errorMessage,
    AccessDenial? denial,
    bool clearError = false,
  }) => AuthState(
    status: status ?? this.status,
    session: session ?? this.session,
    profile: profile ?? this.profile,
    errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    // The denial is part of "the last failure", so clearing the error clears
    // it too — otherwise a stale 403 would outlive the state that caused it.
    denial: clearError ? null : (denial ?? this.denial),
  );
}

/// Coordinates authentication and the profile that depends on it.
///
/// The profile is fetched here rather than in a separate provider because the
/// two are inseparable in practice: the market used by every catalogue request
/// comes from `profile.country`, and the Premium tier gates playback controls.
/// Loading them independently produces a window where the app makes requests
/// with the wrong market.
class AuthRepository {
  AuthRepository({
    required SpotifyAuthService authService,
    required SpotifyUserService userService,
    required PreferencesStore preferences,
    required MetadataCache cache,
  }) : _auth = authService,
       _users = userService,
       _prefs = preferences,
       _cache = cache;

  final SpotifyAuthService _auth;
  final SpotifyUserService _users;
  final PreferencesStore _prefs;
  final MetadataCache _cache;

  Stream<AuthSession?> get onSessionChanged => _auth.onSessionChanged;

  /// Restores a session at startup and loads the profile behind it.
  ///
  /// Also drives the access-denied screen's "check again", which is precisely
  /// the case where a previously recorded 403 must be retried: the user has
  /// just changed something in the Spotify dashboard.
  Future<AuthState> restore() async {
    SpotifyApiService.resetAvailability();
    final session = await _auth.restoreSession();
    if (session == null) return AuthState.signedOut;
    return _stateFor(session);
  }

  /// Runs the interactive sign-in.
  Future<AuthState> signIn() async {
    try {
      final session = await _auth.login();
      return _stateFor(session);
    } on AuthCancelledException {
      // Not an error — the user chose to back out.
      return AuthState.signedOut;
    } on AuthFailedException catch (error) {
      AppLogger.warn('Sign-in failed', scope: 'auth', error: error.debugDetail);
      return AuthState(
        status: AuthStatus.signedOut,
        errorMessage: error.message,
      );
    }
  }

  /// Signs out and clears everything derived from the account.
  ///
  /// Cached metadata is dropped as well as tokens: leaving the previous user's
  /// library on disk would show it to whoever signs in next.
  Future<void> signOut({bool clearCache = true}) async {
    await _auth.clearSession();
    if (clearCache) {
      await _cache.clear();
      await _prefs.remove(PrefKeys.lastPlayedTrack);
      await _prefs.remove(PrefKeys.lastQueue);
      await _prefs.remove(PrefKeys.recentlyViewed);
    }
    SpotifyApiService.market = 'from_token';
    // Endpoint availability is decided per application and per account, so a
    // refusal recorded for the previous session must not silence a request the
    // next one would be allowed to make.
    SpotifyApiService.resetAvailability();
  }

  /// Turns a live session into an [AuthState], including the "Spotify refuses
  /// this account" case.
  Future<AuthState> _stateFor(AuthSession session) async {
    final result = await _loadProfile();
    final denial = result.denial;

    if (denial != null) {
      return AuthState(
        status: AuthStatus.accessDenied,
        session: session,
        denial: denial,
        errorMessage:
            'Spotify is not allowing this account to use the app. This is '
            'configured in the Spotify developer dashboard.',
      );
    }

    return AuthState(
      status: AuthStatus.signedIn,
      session: session,
      profile: result.profile,
    );
  }

  /// Fetches the profile.
  ///
  /// Returns an [AccessDenial] when Spotify answers `403` for `GET /me`,
  /// carrying Spotify's own explanation so the UI can report the real cause
  /// instead of listing candidates.
  ///
  /// That response is diagnostic: `/me` needs no scope, is never restricted by
  /// quota mode, and works for any valid token. A 403 there means Spotify is
  /// refusing the *application* on behalf of this *user* — in practice either
  /// the app is still in Development Mode with this account missing from its
  /// User Management allowlist, or the app has not declared the Web API in its
  /// dashboard settings.
  ///
  /// It deliberately does **not** fall back to the cached profile in that case.
  /// Doing so would let the app look signed in and healthy while every single
  /// request fails — which is precisely the confusing state this branch exists
  /// to prevent. Offline and transient failures still use the cache.
  Future<({UserProfile? profile, AccessDenial? denial})> _loadProfile() async {
    try {
      final profile = await _users.me();
      SpotifyApiService.setMarketFromCountry(profile.country);
      await _cache.writeObject(CacheKeys.userProfile, profile.toJson());
      return (profile: profile, denial: null);
    } on ApiException catch (error) {
      if (error.kind == ApiFailureKind.forbidden) {
        final denial = AccessDenial.fromApiException(error);
        // Spotify's own wording is the whole diagnosis — log it rather than a
        // generic sentence, so the console answers "which dashboard setting?"
        // without anyone having to reproduce the failure behind a proxy.
        AppLogger.error(
          'Spotify refused GET /me for this account — ${denial.summary}. '
          'This is an authorization decision made by the Spotify application '
          '(Client ID in the boot log), not by AURIX.',
          scope: 'auth',
          error: error,
        );
        return (profile: null, denial: denial);
      }
      AppLogger.warn(
        'Profile fetch failed (${error.kind.name}); trying cache',
        scope: 'auth',
      );
      return (profile: _cachedProfile(), denial: null);
    } on Object catch (error) {
      AppLogger.warn('Profile fetch failed; trying cache', scope: 'auth', error: error);
      return (profile: _cachedProfile(), denial: null);
    }
  }

  UserProfile? _cachedProfile() {
    final cached = _cache.readObject(CacheKeys.userProfile);
    if (cached == null) return null;
    try {
      final profile = UserProfile.fromJson(cached.value);
      SpotifyApiService.setMarketFromCountry(profile.country);
      return profile;
    } on Object {
      return null;
    }
  }

  /// Re-reads the profile, e.g. after the user upgrades to Premium and pulls
  /// to refresh on the profile screen.
  Future<UserProfile?> refreshProfile() async => (await _loadProfile()).profile;

  bool hasScope(String scope) => _auth.hasScope(scope);
}
