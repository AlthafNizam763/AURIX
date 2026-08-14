import 'package:aurix/core/config/env.dart';
import 'package:aurix/core/storage/secure_store.dart';
import 'package:aurix/data/services/spotify_auth_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The sign-in failure paths.
///
/// Every case here ends before the token exchange, so none of them touch the
/// network: the point is that each one produces a *typed, display-ready*
/// outcome rather than an unhandled exception. The repository only catches
/// [AuthCancelledException] and [AuthFailedException], so anything else
/// escaping `login()` reaches the UI as a crash.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureStore store;

  /// Builds a service whose browser step returns [result] or throws [error].
  SpotifyAuthService serviceReturning({String? result, Exception? error}) =>
      SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async {
          if (error != null) throw error;
          // Echo the state back so the CSRF check passes unless a test is
          // deliberately breaking it.
          final state = Uri.parse(url).queryParameters['state'];
          return result!.replaceAll('{state}', state ?? '');
        },
      );

  setUp(() {
    store = InMemorySecureStore();
    Env.loadFromString(
      'SPOTIFY_CLIENT_ID=test_client_id\n'
      'SPOTIFY_REDIRECT_URI=aurix://auth-callback\n'
      'SPOTIFY_CALLBACK_SCHEME=aurix\n',
    );
  });

  tearDown(Env.resetForTesting);

  group('configuration', () {
    test('an unconfigured build fails before opening a browser', () async {
      Env.resetForTesting();
      var opened = false;
      final service = SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async {
          opened = true;
          return '';
        },
      );

      await expectLater(service.login(), throwsA(isA<AuthFailedException>()));
      expect(opened, isFalse, reason: 'no point opening a doomed login page');
    });
  });

  group('user cancellation', () {
    test('a dismissed browser sheet is a cancellation, not a failure', () {
      final service = serviceReturning(
        error: PlatformException(code: 'CANCELED', message: 'User canceled'),
      );
      expect(service.login(), throwsA(isA<AuthCancelledException>()));
    });

    test('error=access_denied is treated as a cancellation', () {
      // Spotify sends this both when the consent screen is dismissed and when
      // a Development Mode app refuses an account that is not allowlisted.
      // The two are indistinguishable here; the allowlist case is caught
      // unambiguously by the 403 on GET /me.
      final service = serviceReturning(
        result: 'aurix://auth-callback?error=access_denied&state={state}',
      );
      expect(service.login(), throwsA(isA<AuthCancelledException>()));
    });

    test('cancelling clears the stored code verifier', () async {
      final service = serviceReturning(
        error: PlatformException(code: 'CANCELED', message: 'User canceled'),
      );
      await expectLater(service.login(), throwsA(isA<AuthCancelledException>()));
      expect(await store.read(SecureKeys.codeVerifier), isNull);
    });
  });

  group('OAuth error codes', () {
    Future<String> messageFor(String code) async {
      final service = serviceReturning(
        result: 'aurix://auth-callback?error=$code&state={state}',
      );
      try {
        await service.login();
        fail('expected $code to throw');
      } on AuthFailedException catch (error) {
        return error.message;
      }
    }

    test('invalid_client names the Client ID', () async {
      expect(await messageFor('invalid_client'), contains('SPOTIFY_CLIENT_ID'));
    });

    test('invalid_request names the redirect URI', () async {
      final message = await messageFor('invalid_request');
      expect(message, contains('Redirect URI'));
      expect(message, contains('aurix://auth-callback'));
    });

    test('server_error asks the user to retry', () async {
      expect(await messageFor('server_error'), contains('try again'));
    });

    test('an unrecognised code still produces a usable message', () async {
      expect(await messageFor('something_new'), isNotEmpty);
    });

    test('the raw OAuth code is kept out of the user-facing message', () async {
      // debugDetail carries it for the logs; message must not.
      final service = serviceReturning(
        result: 'aurix://auth-callback?error=invalid_scope&'
            'error_description=secret_internal_detail&state={state}',
      );
      try {
        await service.login();
        fail('expected a failure');
      } on AuthFailedException catch (error) {
        expect(error.message, isNot(contains('secret_internal_detail')));
        expect(error.debugDetail, contains('secret_internal_detail'));
      }
    });
  });

  group('malformed and hostile callbacks', () {
    test('a state mismatch aborts without exchanging the code', () async {
      final service = SpotifyAuthService(
        secureStore: store,
        // Return someone else's state — a forged or replayed redirect.
        authenticate: ({required url, required callbackUrlScheme}) async =>
            'aurix://auth-callback?code=abc&state=not_the_state_we_sent',
      );
      await expectLater(service.login(), throwsA(isA<AuthFailedException>()));
      expect(await store.read(SecureKeys.codeVerifier), isNull);
    });

    test('a callback with no code fails cleanly', () {
      final service = serviceReturning(
        result: 'aurix://auth-callback?state={state}',
      );
      expect(service.login(), throwsA(isA<AuthFailedException>()));
    });

    test('an unparseable callback does not escape as a FormatException', () {
      // Uri.parse used to run outside the guarded block, so a non-URL reached
      // the repository as a raw FormatException and crashed sign-in.
      final service = SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async =>
            'http://[this is not a uri',
      );
      expect(service.login(), throwsA(isA<AuthFailedException>()));
    });

    test('parameters in the fragment are read as well as the query', () async {
      // Some providers return the result after a '#'. Reading only the query
      // would look like "Spotify returned no authorization code".
      final service = SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async {
          final state = Uri.parse(url).queryParameters['state'];
          return 'aurix://auth-callback#error=server_error&state=$state';
        },
      );
      try {
        await service.login();
        fail('expected a failure');
      } on AuthFailedException catch (error) {
        expect(error.message, contains('try again'));
      }
    });
  });

  group('no redirect at all', () {
    test('a timeout points at the unregistered redirect URI', () async {
      // What an unrecognised redirect URI actually looks like from the app:
      // Spotify renders "INVALID_CLIENT: Invalid redirect URI" and never
      // redirects, so the plugin simply times out.
      final service = serviceReturning(
        error: PlatformException(
          code: 'error',
          message: 'Timeout waiting for callback value',
        ),
      );
      try {
        await service.login();
        fail('expected a failure');
      } on AuthFailedException catch (error) {
        expect(error.message, contains('Redirect URI'));
        expect(error.message, contains('aurix://auth-callback'));
      }
    });
  });

  group('the authorize request', () {
    test('sends PKCE S256, a state, and no client secret', () async {
      late final Uri authorizeUrl;
      final service = SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async {
          authorizeUrl = Uri.parse(url);
          throw const AuthCancelledException();
        },
      );

      await expectLater(service.login(), throwsA(isA<AuthCancelledException>()));

      final query = authorizeUrl.queryParameters;
      expect(query['response_type'], 'code');
      expect(query['code_challenge_method'], 'S256');
      expect(query['code_challenge'], isNotEmpty);
      expect(query['state'], isNotEmpty);
      expect(query['client_id'], 'test_client_id');
      expect(query['redirect_uri'], 'aurix://auth-callback');
      // The whole point of PKCE: nothing secret is ever sent from the client.
      expect(query.keys, isNot(contains('client_secret')));
      expect(authorizeUrl.toString(), isNot(contains('secret')));
    });

    test('persists the verifier so a killed app can still finish', () async {
      // Android routinely kills the app while the browser is in front.
      var seenVerifier = '';
      final service = SpotifyAuthService(
        secureStore: store,
        authenticate: ({required url, required callbackUrlScheme}) async {
          seenVerifier = await store.read(SecureKeys.codeVerifier) ?? '';
          throw const AuthCancelledException();
        },
      );

      await expectLater(service.login(), throwsA(isA<AuthCancelledException>()));
      expect(seenVerifier, isNotEmpty);
      expect(seenVerifier.length, greaterThanOrEqualTo(43));
    });
  });

  group('session lifecycle', () {
    test('restoring with nothing stored yields no session', () async {
      final service = serviceReturning(result: '');
      expect(await service.restoreSession(), isNull);
      expect(service.isAuthenticated, isFalse);
    });

    test('logging out clears every credential', () async {
      await store.write(SecureKeys.accessToken, 'a');
      await store.write(SecureKeys.refreshToken, 'r');
      await store.write(SecureKeys.expiresAt, DateTime.now().toIso8601String());
      await store.write(SecureKeys.scopes, 'user-read-private');
      await store.write(SecureKeys.codeVerifier, 'v');

      final service = serviceReturning(result: '');
      await service.clearSession();

      expect(store.snapshot, isEmpty);
      expect(service.session, isNull);
      expect(service.isAuthenticated, isFalse);
    });

    test('a stored session with an unreadable expiry is discarded', () async {
      await store.write(SecureKeys.accessToken, 'a');
      await store.write(SecureKeys.expiresAt, 'not a date');

      final service = serviceReturning(result: '');
      expect(await service.restoreSession(), isNull);
      expect(store.snapshot, isEmpty);
    });
  });
}
