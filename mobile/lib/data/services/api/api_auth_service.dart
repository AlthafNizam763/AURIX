import 'dart:async';

import '../../../core/config/env.dart';
import '../../../core/constants/aurix_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/aurix_api_client.dart';
import '../../../core/utils/app_logger.dart';
import '../../models/aurix_user.dart';
import '../../models/auth_challenge.dart';
import '../../models/auth_method.dart';
import 'aurix_session_store.dart';
import 'oauth_launcher.dart';

/// Why an authentication attempt failed, in terms the UI can act on.
///
/// The API reports failures as a stable `error.code` string. They are mapped to
/// this enum rather than passed through, for the same two reasons the Firebase
/// codes were: raw codes leak into UI that then has to know the backend's
/// vocabulary, and several distinct codes mean one thing to a user.
///
/// The enum itself is unchanged from the Firebase version — same cases, same
/// sentences — because the screens that switch on it did not need to change
/// when the backend did. Only the mapping in [AuthFailure.from] moved.
enum AuthFailureKind {
  /// The email/password pair does not identify an account.
  ///
  /// One case for "no such account" and "wrong password", deliberately. Telling
  /// an attacker which half was wrong is an account-enumeration oracle, and the
  /// API is written not to distinguish them either — see the login route, which
  /// runs the password comparison even when there is no account so the two
  /// paths take the same time.
  invalidCredentials,

  /// The address is already registered.
  emailAlreadyInUse,

  /// Not a valid email address.
  invalidEmail,

  /// The password is below the minimum length.
  weakPassword,

  /// Disabled by an administrator.
  userDisabled,

  /// Too many attempts. The API rate-limits the credential routes per IP.
  tooManyRequests,

  /// The request could not reach the AURIX API.
  network,

  /// The API is reachable but this build has no server configured at all. A
  /// setup mistake rather than a user error, and worth its own case because the
  /// fix is in `.env` rather than in the form.
  notConfigured,

  /// The session is too old, or the current password given was wrong.
  requiresRecentLogin,

  // ---- The other ways in -------------------------------------------------

  /// That does not look like a phone number.
  invalidPhone,

  /// The one-time code is wrong.
  invalidCode,

  /// The one-time code has expired, or too many wrong ones burned it.
  codeExpired,

  /// The number is already on another AURIX account.
  phoneAlreadyInUse,

  /// This exact provider account is a way into a *different* AURIX account.
  ///
  /// Deliberately not folded into [emailAlreadyInUse]: the remedy is entirely
  /// different. There is no password to reset here — the fix is to unlink it
  /// from the other account, or to sign in to that one instead.
  identityAlreadyLinked,

  /// This deployment has no credentials for that provider.
  providerUnavailable,

  /// This deployment cannot deliver an SMS, so phone sign-in is switched off.
  ///
  /// Distinct from [providerUnavailable] because the remedy differs: there is
  /// no third party to sign in to, and the user's next step is a different
  /// method rather than a different account.
  otpUnavailable,

  /// The browser flow, or the pending link, is no longer valid.
  linkExpired,

  /// Removing it would leave no way back into the account.
  lastSignInMethod,

  /// The user dismissed the provider's page. Not shown — see [AuthFailure].
  cancelled,

  /// Anything else.
  unknown;

  /// A sentence to put in front of the user.
  ///
  /// Written to say what to do next, not to restate the error. "Wrong password"
  /// tells someone nothing they had not worked out; naming the two things that
  /// could be wrong gives them somewhere to go.
  String get message {
    switch (this) {
      case AuthFailureKind.invalidCredentials:
        return 'That email and password do not match an AURIX account. '
            'Check both, or create an account if you have not yet.';
      case AuthFailureKind.emailAlreadyInUse:
        return 'An AURIX account already exists for that email. '
            'Sign in instead, or reset the password.';
      case AuthFailureKind.invalidEmail:
        return 'That does not look like an email address.';
      case AuthFailureKind.weakPassword:
        return 'Choose a longer password — at least eight characters.';
      case AuthFailureKind.userDisabled:
        return 'This account has been disabled.';
      case AuthFailureKind.tooManyRequests:
        return 'Too many attempts. Wait a moment and try again.';
      case AuthFailureKind.network:
        return 'AURIX cannot reach its server. Check your connection and '
            'try again.';
      case AuthFailureKind.notConfigured:
        return 'AURIX is not connected to a server yet. Set '
            'AURIX_API_BASE_URL in .env and start the API in server/.';
      case AuthFailureKind.requiresRecentLogin:
        return 'For security, confirm your current password before making '
            'this change.';
      case AuthFailureKind.invalidPhone:
        return 'That does not look like a phone number. Include the country '
            'code, for example +44 7700 900123.';
      case AuthFailureKind.invalidCode:
        return 'That code is not correct. Check it and try again.';
      case AuthFailureKind.codeExpired:
        return 'That code has expired. Ask for a new one.';
      case AuthFailureKind.phoneAlreadyInUse:
        return 'That number is already on another AURIX account. Sign in with '
            'it instead.';
      case AuthFailureKind.identityAlreadyLinked:
        return 'That account is already linked to a different AURIX account. '
            'Sign in with it, or unlink it there first.';
      case AuthFailureKind.providerUnavailable:
        return 'That way of signing in is not available on this AURIX server.';
      case AuthFailureKind.otpUnavailable:
        return 'Signing in by phone is not available on this AURIX server. '
            'Use your email and password, or another method.';
      case AuthFailureKind.linkExpired:
        return 'That sign-in took too long. Start again.';
      case AuthFailureKind.lastSignInMethod:
        return 'That is the only way into this account. Add a password or '
            'another sign-in method before removing it.';
      case AuthFailureKind.cancelled:
        // Never reaches a user. `AuthController` drops this case rather than
        // showing it: a banner reading "sign-in cancelled" immediately after
        // somebody cancelled sign-in is noise, not information.
        return 'Sign-in cancelled.';
      case AuthFailureKind.unknown:
        return 'Sign-in failed. Please try again.';
    }
  }
}

/// A failed authentication attempt.
class AuthFailure implements Exception {
  const AuthFailure(this.kind, {this.code, this.detail});

  final AuthFailureKind kind;

  /// The API's own code, kept for the log. Never shown to the user.
  final String? code;

  /// The API's own message. Shown *in preference to* [AuthFailureKind.message]
  /// when present — see [message] — because the server writes these to be read.
  final String? detail;

  /// What to show the user.
  ///
  /// Prefers the server's sentence for the codes where it carries information
  /// this enum cannot: a rate-limit message that names the window, a validation
  /// message that names the field. Falls back to the enum's own copy otherwise,
  /// which is what covers a failure that never reached the server.
  String get message {
    if (kind == AuthFailureKind.unknown && (detail?.isNotEmpty ?? false)) {
      return detail!;
    }
    return kind.message;
  }

  factory AuthFailure.from(Object error) {
    if (error is AuthFailure) return error;

    // The browser flow reports these, and they are not API errors — they never
    // reached the API. Mapped here so every caller can keep one catch.
    if (error is SocialSignInCancelled) {
      return const AuthFailure(AuthFailureKind.cancelled);
    }
    if (error is SocialSignInRejected) {
      return AuthFailure(
        switch (error.code) {
          'provider_unavailable' => AuthFailureKind.providerUnavailable,
          'invalid_auth_state' => AuthFailureKind.linkExpired,
          'identity_in_use' => AuthFailureKind.identityAlreadyLinked,
          'rate_limited' => AuthFailureKind.tooManyRequests,
          _ => AuthFailureKind.unknown,
        },
        code: error.code,
        detail: error.message,
      );
    }

    if (error is AurixApiException) {
      final kind = switch (error.code) {
        'invalid_credentials' => AuthFailureKind.invalidCredentials,
        'email_in_use' => AuthFailureKind.emailAlreadyInUse,
        'invalid_email' => AuthFailureKind.invalidEmail,
        'weak_password' => AuthFailureKind.weakPassword,
        'user_disabled' => AuthFailureKind.userDisabled,
        'rate_limited' => AuthFailureKind.tooManyRequests,
        'not_configured' => AuthFailureKind.notConfigured,
        'invalid_phone' => AuthFailureKind.invalidPhone,
        'invalid_code' => AuthFailureKind.invalidCode,
        'code_expired' => AuthFailureKind.codeExpired,
        'phone_in_use' => AuthFailureKind.phoneAlreadyInUse,
        'identity_in_use' => AuthFailureKind.identityAlreadyLinked,
        'provider_unavailable' => AuthFailureKind.providerUnavailable,
        'otp_unavailable' => AuthFailureKind.otpUnavailable,
        'invalid_auth_state' => AuthFailureKind.linkExpired,
        'last_sign_in_method' => AuthFailureKind.lastSignInMethod,
        'unauthenticated' || 'token_expired' => AuthFailureKind.requiresRecentLogin,
        // `bad_request` is what a schema rejection arrives as. The server's
        // own message names the field, which is more useful than anything
        // this enum could say, so it is carried through as `unknown` — the one
        // case where [message] prefers the server's sentence.
        _ => switch (error.kind) {
          ApiFailureKind.offline || ApiFailureKind.timeout => AuthFailureKind.network,
          _ => AuthFailureKind.unknown,
        },
      };
      return AuthFailure(kind, code: error.code, detail: error.message);
    }

    if (error is ApiException) {
      final kind = switch (error.kind) {
        ApiFailureKind.offline || ApiFailureKind.timeout => AuthFailureKind.network,
        ApiFailureKind.unauthorized => AuthFailureKind.invalidCredentials,
        _ => AuthFailureKind.unknown,
      };
      return AuthFailure(kind, detail: error.message);
    }

    if (error is AurixSessionEnded) {
      return const AuthFailure(AuthFailureKind.requiresRecentLogin);
    }

    return AuthFailure(AuthFailureKind.unknown, detail: error.toString());
  }

  @override
  String toString() => 'AuthFailure(${kind.name}${code == null ? '' : ', $code'})';
}

/// AURIX's front door to its own identity service.
///
/// The replacement for `FirebaseAuthService`. What changed underneath is
/// everything; what changed at this boundary is almost nothing, which is the
/// point — [AuthRepository] and the sign-in screens speak the same methods and
/// the same [AuthFailure] they always did.
///
/// ## Session persistence
///
/// Firebase persisted the session for us and replayed it through
/// `authStateChanges()` on the first frame. Nothing does that now, so
/// [AurixSessionStore] does it explicitly: it holds the tokens in the platform
/// keystore, restores them during `bootstrap()`, and publishes the same
/// stream shape through [authStateChanges].
///
/// ## Tokens
///
/// Firebase attached and refreshed an ID token inside its SDK, so AURIX had no
/// bearer token to manage. It has one now, and it is managed in exactly two
/// places: [AurixSessionStore] holds it and [AurixApiClient] attaches it.
/// Nothing else in the app has ever seen it and nothing else should.
class ApiAuthService {
  ApiAuthService({
    required AurixApiClient client,
    required AurixSessionStore session,
    OAuthLauncher? launcher,
  }) : _client = client,
       _session = session,
       _launcher = launcher ?? OAuthLauncher();

  final AurixApiClient _client;
  final AurixSessionStore _session;

  /// The browser half of a social sign-in. Injected so a test can drive the
  /// whole flow without a system browser.
  final OAuthLauncher _launcher;

  /// The session, as a stream. The replacement for `authStateChanges()`.
  Stream<AurixUser?> authStateChanges() => _session.changes();

  AurixUser? get currentUser => _session.currentUser;

  Future<AurixUser> register({
    required String email,
    required String password,
    required String name,
  }) => _authenticate(
    AurixEndpoints.register,
    <String, dynamic>{'email': email.trim(), 'password': password, 'name': name.trim()},
    'register',
  );

  Future<AurixUser> signIn({required String email, required String password}) =>
      _authenticate(
        AurixEndpoints.login,
        <String, dynamic>{'email': email.trim(), 'password': password},
        'signIn',
      );

  /// Sends credentials, stores the session it gets back, and returns the user.
  Future<AurixUser> _authenticate(
    String path,
    Map<String, dynamic> body,
    String operation,
  ) async {
    try {
      return await _storeSession(await _client.post(path, body: body));
    } on Object catch (error) {
      throw _reported(error, operation);
    }
  }

  /// Persists a session payload and announces it.
  ///
  /// Split out of [_authenticate] when AURIX grew five more ways in. Every one
  /// of them ends here — a phone code, each of the four providers, the
  /// account-link confirmation — because the server produces one payload shape
  /// for all of them (see `services/session.js`) and this is the one piece of
  /// code that reads it. A second copy would be a second opinion about what a
  /// session is.
  Future<AurixUser> _storeSession(Map<String, dynamic> response) async {
    final user = _userIn(response);

    await _session.save(
      accessToken: response['accessToken'] as String,
      refreshToken: response['refreshToken'] as String,
      expiresAt:
          DateTime.tryParse(response['expiresAt'] as String? ?? '') ??
          DateTime.now().add(const Duration(days: 60)),
      user: user,
    );

    return user;
  }

  /// Ends the session — locally always, and server-side when reachable.
  ///
  /// The order matters. The local clear happens whatever the network does,
  /// because a sign-out that fails because the user is offline is a sign-out
  /// that did not happen, and they are still looking at their library. The
  /// server call revokes the refresh token so it cannot be replayed; if it
  /// fails, the token expires on its own schedule.
  Future<void> signOut() async {
    final refreshToken = await _session.readRefreshToken();
    await _session.clear();

    if (refreshToken == null) return;
    try {
      await _client.post(
        AurixEndpoints.logout,
        body: <String, dynamic>{'refreshToken': refreshToken},
      );
    } on Object catch (error) {
      AppLogger.debug('Could not revoke the session server-side: $error', scope: 'auth');
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    try {
      final response = await _client.post(
        AurixEndpoints.forgotPassword,
        body: <String, dynamic>{'email': email.trim()},
      );

      // Present only when the server has no mail transport and is not in
      // production — see the route. It is logged, never shown: a code on
      // screen would make the "if that address is registered" wording a lie.
      final devToken = response['devToken'];
      if (devToken is String) {
        AppLogger.warn(
          'The API has no SMTP configured. Password reset token for this '
          'request: $devToken',
          scope: 'auth',
        );
      }
    } on Object catch (error) {
      throw _reported(error, 'sendPasswordResetEmail');
    }
  }

  /// Completes a reset with the token from the email.
  Future<void> resetPassword({required String token, required String password}) async {
    try {
      await _client.post(
        AurixEndpoints.resetPassword,
        body: <String, dynamic>{'token': token, 'password': password},
      );
    } on Object catch (error) {
      throw _reported(error, 'resetPassword');
    }
  }

  /// Changes the password, re-authenticating with the current one.
  ///
  /// One call rather than the reauthenticate-then-update pair Firebase needed.
  /// The server checks the current password and rotates the session in the same
  /// request, which removes the window where the old password had been accepted
  /// and the new one not yet set.
  /// [currentPassword] is null only for an account that has never had one —
  /// created by "Continue with Google" or by a phone code. The server demands
  /// it wherever a password exists, so this can never become a way to replace
  /// a password without knowing it; what it allows is *setting the first one*,
  /// which is authorised by holding a live session for the account.
  Future<void> updatePassword({
    String? currentPassword,
    required String newPassword,
  }) async {
    try {
      final response = await _client.post(
        AurixEndpoints.changePassword,
        body: <String, dynamic>{
          if (currentPassword != null && currentPassword.isNotEmpty)
            'currentPassword': currentPassword,
          'newPassword': newPassword,
        },
      );

      // The change revokes every refresh token, including this device's. The
      // response carries a replacement pair so the user is not signed out of
      // the device they just changed the password on.
      await _session.saveTokens(
        accessToken: response['accessToken'] as String,
        refreshToken: response['refreshToken'] as String,
        expiresAt:
            DateTime.tryParse(response['expiresAt'] as String? ?? '') ??
            DateTime.now().add(const Duration(days: 60)),
      );
    } on Object catch (error) {
      throw _reported(error, 'updatePassword');
    }
  }

  Future<void> sendEmailVerification() async {
    try {
      final response = await _client.post(AurixEndpoints.sendVerification);
      final devToken = response['devToken'];
      if (devToken is String) {
        AppLogger.warn(
          'The API has no SMTP configured. Verification token: $devToken',
          scope: 'auth',
        );
      }
    } on Object catch (error) {
      throw _reported(error, 'sendEmailVerification');
    }
  }

  Future<AurixUser?> verifyEmail(String token) async {
    try {
      final response = await _client.post(
        AurixEndpoints.verifyEmail,
        body: <String, dynamic>{'token': token},
      );
      final user = _userIn(response);
      await _session.saveUser(user);
      return user;
    } on Object catch (error) {
      throw _reported(error, 'verifyEmail');
    }
  }

  /// Re-reads the account from the server.
  ///
  /// The replacement for `User.reload()`. Returns null rather than throwing
  /// when the session is gone, because every caller treats "no user" and "could
  /// not read the user" the same way.
  Future<AurixUser?> reload() async {
    try {
      final response = await _client.get(AurixEndpoints.me);
      final user = _userIn(response);
      await _session.saveUser(user);
      return user;
    } on Object catch (error) {
      AppLogger.debug('Could not reload the account: $error', scope: 'auth');
      return null;
    }
  }

  Future<void> updateDisplayName(String name) async {
    try {
      final response = await _client.patch(
        AurixEndpoints.me,
        body: <String, dynamic>{'name': name.trim()},
      );
      await _session.saveUser(_userIn(response));
    } on Object catch (error) {
      throw _reported(error, 'updateDisplayName');
    }
  }

  /// Deletes the account and everything under it.
  ///
  /// The shared catalogue is deliberately untouched — see the route. A playlist
  /// this account contributed is one other users are listening to, and leaving
  /// is not a reason to take it from them.
  Future<void> deleteAccount(String password) async {
    try {
      await _client.delete(
        AurixEndpoints.deleteAccount,
        body: <String, dynamic>{'password': password},
      );
      await _session.clear();
    } on Object catch (error) {
      throw _reported(error, 'deleteAccount');
    }
  }

  // -------------------------------------------------------------------------
  // Which ways in this deployment offers
  // -------------------------------------------------------------------------

  /// Read once, before the login screen is drawn.
  ///
  /// A provider whose credentials the server does not hold is left off the
  /// screen entirely, rather than offered and then failing in a browser tab
  /// with a message from Google about an unregistered client. The difference
  /// is between a button that is absent and a button that is broken.
  ///
  /// Falls back to email and password on any failure. That is the one method
  /// that needs no configuration beyond the database, so it is the honest
  /// answer when the server cannot be asked — and it keeps the login screen
  /// usable while the API is briefly unreachable.
  Future<List<AuthMethod>> availableMethods() async {
    try {
      final response = await _client.get(AurixEndpoints.authMethods);
      final methods = AuthMethod.fromIds(response['methods']);
      return methods.isEmpty ? const [AuthMethod.password] : methods;
    } on Object catch (error) {
      AppLogger.debug(
        'Could not read the available sign-in methods: $error',
        scope: 'auth',
      );
      return const [AuthMethod.password];
    }
  }

  // -------------------------------------------------------------------------
  // Phone
  // -------------------------------------------------------------------------

  /// Sends a one-time code.
  ///
  /// [linkToCurrentAccount] attaches the number to the session already open
  /// instead of signing in with it — which is what keeps a user who registered
  /// by email from acquiring a second account the first time they try their
  /// phone. The distinction is made by the bearer token on this request, and
  /// the server refuses `link` without one.
  Future<PhoneCodeRequest> startPhoneSignIn(
    String phone, {
    bool linkToCurrentAccount = false,
  }) async {
    try {
      final response = await _client.post(
        AurixEndpoints.phoneStart,
        body: <String, dynamic>{
          'phone': phone.trim(),
          'intent': linkToCurrentAccount ? 'link' : 'signIn',
        },
      );
      // Nothing is logged about this response. It carries no code — the API
      // does not return one — and the timings and masked number it does carry
      // are the caller's to render, not this layer's to narrate.
      return PhoneCodeRequest.fromJson(response);
    } on Object catch (error) {
      throw _reported(error, 'startPhoneSignIn');
    }
  }

  /// Redeems a code and signs in, creating the account if the number is new.
  Future<AurixUser> verifyPhoneCode({
    required String phone,
    required String code,
    String? name,
  }) async {
    try {
      return await _storeSession(
        await _client.post(
          AurixEndpoints.phoneVerify,
          body: <String, dynamic>{
            'phone': phone.trim(),
            'code': code.trim(),
            if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
          },
        ),
      );
    } on Object catch (error) {
      throw _reported(error, 'verifyPhoneCode');
    }
  }

  /// Attaches a number to the account already signed in.
  ///
  /// Returns the refreshed account rather than a session: the caller is
  /// already authenticated, and rotating their tokens here would be churn for
  /// nothing.
  Future<AurixUser> linkPhone({required String phone, required String code}) async {
    try {
      final response = await _client.post(
        AurixEndpoints.phoneLink,
        body: <String, dynamic>{'phone': phone.trim(), 'code': code.trim()},
      );
      final user = _userIn(response);
      await _session.saveUser(user);
      return user;
    } on Object catch (error) {
      throw _reported(error, 'linkPhone');
    }
  }

  // -------------------------------------------------------------------------
  // Google, Apple, Facebook, GitHub
  // -------------------------------------------------------------------------

  /// Signs in with a provider, or reports that an account link is needed.
  ///
  /// See [PendingAccountLink] for why the second outcome is a value rather
  /// than an error.
  Future<AuthResult> signInWith(AuthMethod provider) =>
      _browserFlow(provider, intent: 'signIn', operation: 'signInWith');

  /// Adds a provider to the account already signed in.
  ///
  /// Cannot produce a link challenge: the account is decided by the bearer
  /// token before the browser opens, and the server writes it into the flow's
  /// state row — so nothing that comes back through the browser can redirect
  /// the link somewhere else.
  Future<AurixUser> linkProvider(AuthMethod provider) async {
    final result = await _browserFlow(
      provider,
      intent: 'link',
      operation: 'linkProvider',
    );
    final user = result.user;
    if (user == null) {
      throw const AuthFailure(
        AuthFailureKind.unknown,
        detail: 'The server asked to link an account that is already signed in.',
      );
    }
    return user;
  }

  /// Start, browser, exchange — the three hops, written once.
  ///
  /// The provider's tokens are never seen here and neither is any client
  /// secret. What comes back from the browser is a single-use AURIX grant that
  /// only the API can redeem; everything that decided anything happened on the
  /// server. See `services/oauth/flow.js` for the diagram.
  Future<AuthResult> _browserFlow(
    AuthMethod provider, {
    required String intent,
    required String operation,
  }) async {
    try {
      final start = await _client.post(
        AurixEndpoints.oauthStart(provider.id),
        body: <String, dynamic>{
          'redirectUri': Env.loginRedirectUri,
          'intent': intent,
        },
      );

      final url = start['authorizationUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw const AuthFailure(AuthFailureKind.providerUnavailable);
      }

      final grant = await _launcher.awaitGrant(url);

      final response = await _client.post(
        AurixEndpoints.oauthExchange,
        body: <String, dynamic>{'code': grant},
      );

      if (response['linkRequired'] == true) {
        return AuthResult.linkRequired(PendingAccountLink.fromJson(response));
      }
      return AuthResult.signedIn(await _storeSession(response));
    } on Object catch (error) {
      throw _reported(error, '$operation(${provider.id})');
    }
  }

  // -------------------------------------------------------------------------
  // Joining two accounts that turned out to be one person
  // -------------------------------------------------------------------------

  /// Sends a confirmation code to the *existing* account's address.
  Future<LinkCodeSent> sendAccountLinkCode(String linkToken) async {
    try {
      final response = await _client.post(
        AurixEndpoints.linkCode,
        body: <String, dynamic>{'linkToken': linkToken},
      );
      return LinkCodeSent.fromJson(response);
    } on Object catch (error) {
      throw _reported(error, 'sendAccountLinkCode');
    }
  }

  /// Proves ownership and completes the link, returning a full session.
  ///
  /// Completing a link *is* signing in — it is what the user was trying to do
  /// when they tapped "Continue with Google", and asking for the proof twice
  /// would be gratuitous.
  Future<AurixUser> confirmAccountLink({
    required String linkToken,
    String? password,
    String? code,
  }) async {
    try {
      return await _storeSession(
        await _client.post(
          AurixEndpoints.linkConfirm,
          body: <String, dynamic>{
            'linkToken': linkToken,
            if (password != null && password.isNotEmpty) 'password': password,
            if (code != null && code.trim().isNotEmpty) 'code': code.trim(),
          },
        ),
      );
    } on Object catch (error) {
      throw _reported(error, 'confirmAccountLink');
    }
  }

  /// Abandons a pending link — "no, that is not my account".
  ///
  /// Best effort. The grant expires on its own in a few minutes, so a failure
  /// here costs nothing and must not stop the user leaving the sheet.
  Future<void> cancelAccountLink(String linkToken) async {
    try {
      await _client.post(
        AurixEndpoints.linkCancel,
        body: <String, dynamic>{'linkToken': linkToken},
      );
    } on Object catch (error) {
      AppLogger.debug('Could not cancel the pending link: $error', scope: 'auth');
    }
  }

  /// Removes a way in. The server refuses to remove the last one.
  Future<AurixUser> unlink(AuthMethod method) async {
    try {
      final response = await _client.delete(AurixEndpoints.authMethod(method.id));
      final user = _userIn(response);
      await _session.saveUser(user);
      return user;
    } on Object catch (error) {
      throw _reported(error, 'unlink(${method.id})');
    }
  }

  AurixUser _userIn(Map<String, dynamic> response) {
    final body = response['user'];
    if (body is! Map<String, dynamic>) {
      throw const AuthFailure(
        AuthFailureKind.unknown,
        detail: 'The server did not return an account.',
      );
    }
    return AurixUser.fromDocument(body['uid'] as String? ?? '', body);
  }

  /// Logs the technical detail and returns the failure to throw.
  ///
  /// One place, so no call site decides how much of a failure to log — and so
  /// that the raw message reaches the log exactly once and the UI never.
  AuthFailure _reported(Object error, String operation) {
    final failure = AuthFailure.from(error);
    final line =
        'Auth $operation failed: ${failure.kind.name}'
        '${failure.code == null ? '' : ' (${failure.code})'}';

    // A dismissed consent screen is a user decision, not a fault. Logging it
    // at warn would fill the log with the second most common outcome of an
    // OAuth flow and train everyone to ignore the level.
    if (failure.kind == AuthFailureKind.cancelled) {
      AppLogger.debug(line, scope: 'auth');
    } else {
      AppLogger.warn(line, scope: 'auth');
    }
    return failure;
  }
}
