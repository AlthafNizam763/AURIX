import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';

import '../../../core/config/env.dart';

/// Raised when the user dismisses the provider's page.
///
/// Not an error. Backing out of a consent screen is the second most common
/// thing to do on one, and the UI answers it by returning to the login screen
/// with nothing to say — a red banner reading "sign-in cancelled" after the
/// user cancelled sign-in is noise.
class SocialSignInCancelled implements Exception {
  const SocialSignInCancelled();

  @override
  String toString() => 'SocialSignInCancelled';
}

/// Raised when the browser came home with something other than a grant.
class SocialSignInRejected implements Exception {
  const SocialSignInRejected(this.code, this.message);

  /// The API's or the provider's error code — `access_denied`,
  /// `provider_unavailable`, `invalid_auth_state`, and so on.
  final String code;
  final String message;

  @override
  String toString() => 'SocialSignInRejected($code): $message';
}

/// The browser half of a social sign-in.
///
/// ## What this class does and does not know
///
/// It opens a URL and waits for a redirect to come back to AURIX. That is all.
/// It does not know which provider is involved, it never sees a client secret
/// or a provider token, and it cannot mint a session — the value it returns is
/// a one-time AURIX grant that only the API can redeem.
///
/// That narrowness is the security property, not an accident of layering. The
/// browser is the one part of the flow running outside the app's control, so
/// the less that is entrusted to what comes back from it, the better: what
/// comes back here is a code, a state, or an error, and every one of them is
/// re-checked on the server before it means anything.
///
/// ## The ephemeral session
///
/// `preferEphemeral` keeps the system browser's cookie jar out of the flow.
/// Without it, "sign in with a different Google account" is impossible on a
/// shared device — the browser silently reuses the session that is already
/// there and the chooser never appears. It also means AURIX never inherits a
/// login the user did not perform for AURIX.
class OAuthLauncher {
  OAuthLauncher({
    Future<String> Function({required String url, required String callbackUrlScheme})?
    authenticate,
  }) : _authenticate = authenticate ?? _defaultAuthenticate;

  final Future<String> Function({required String url, required String callbackUrlScheme})
  _authenticate;

  /// Long enough for a password manager, a 2FA prompt and a slow consent page;
  /// short enough that a misregistered redirect URI does not leave the button
  /// spinning for ever.
  static const int _timeoutSeconds = 300;

  /// Opens [authorizationUrl] and returns the grant the API redirected back.
  ///
  /// Throws [SocialSignInCancelled] if the user backed out, and
  /// [SocialSignInRejected] if the callback carried an error instead of a code.
  Future<String> awaitGrant(String authorizationUrl) async {
    final String callback;
    try {
      callback = await _authenticate(
        url: authorizationUrl,
        callbackUrlScheme: Env.loginCallbackScheme,
      );
    } on PlatformException catch (error) {
      // The plugin reports a dismissed browser as a PlatformException, which
      // is indistinguishable from a real failure by type alone. `CANCELED` is
      // the code it uses on both Android and iOS.
      if (error.code == 'CANCELED' || error.code.toLowerCase().contains('cancel')) {
        throw const SocialSignInCancelled();
      }
      rethrow;
    }

    final uri = Uri.tryParse(callback);
    if (uri == null) {
      throw const SocialSignInRejected(
        'invalid_callback',
        'That sign-in came back in a form AURIX could not read.',
      );
    }

    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      // The user pressing Cancel arrives here rather than as a dismissal,
      // because the provider redirected — it just redirected with a refusal.
      if (error == 'access_denied' || error == 'user_cancelled_login') {
        throw const SocialSignInCancelled();
      }
      throw SocialSignInRejected(
        error,
        uri.queryParameters['error_description']?.trim().isNotEmpty == true
            ? uri.queryParameters['error_description']!
            : 'That sign-in could not be completed.',
      );
    }

    final code = uri.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const SocialSignInRejected(
        'missing_code',
        'That sign-in did not come back with anything AURIX could use.',
      );
    }
    return code;
  }

  static Future<String> _defaultAuthenticate({
    required String url,
    required String callbackUrlScheme,
  }) => FlutterWebAuth2.authenticate(
    url: url,
    callbackUrlScheme: callbackUrlScheme,
    options: FlutterWebAuth2Options(
      preferEphemeral: true,
      timeout: _timeoutSeconds,
      // Web only. The plugin discards any postMessage whose origin is not this
      // value. Naming the redirect's own origin is right either way, and it is
      // what makes the local `localhost` / `127.0.0.1` split work — see the
      // long note on [Env.webRedirectOrigin].
      debugOrigin: kIsWeb && _webOrigin.isNotEmpty ? _webOrigin : null,
    ),
  );

  static String get _webOrigin {
    final uri = Uri.tryParse(Env.loginWebRedirectUri);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }
}
