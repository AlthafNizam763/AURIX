import 'package:aurix/core/config/env.dart';
import 'package:flutter_test/flutter_test.dart';

/// Redirect-URI resolution and the explicit-content policy.
///
/// Both are small pieces of logic whose failure mode is expensive and remote:
/// a redirect URI Spotify rejects fails on Spotify's servers with no useful
/// message, and an explicit-content policy that guesses wrong either hides
/// content it should show or offers a switch Spotify has locked.
void main() {
  group('Env redirect URIs', () {
    test('the native redirect URI is the custom scheme', () {
      // No .env is loaded under `flutter test`, so this exercises the built-in
      // fallback — which must stay in step with AndroidManifest.xml,
      // Info.plist and the dashboard entry.
      expect(Env.nativeRedirectUri, 'aurix://auth-callback');
    });

    test('the callback scheme is derived from the native URI', () {
      expect(Env.spotifyCallbackScheme, 'aurix');
    });

    test('off the web, the resolved redirect URI is the native one', () {
      // `flutter test` runs on the VM, so kIsWeb is false here.
      expect(Env.spotifyRedirectUri, Env.nativeRedirectUri);
      expect(Env.defaultWebRedirectUri, isEmpty);
    });

    group('loopback host rewriting', () {
      // Spotify stopped accepting `localhost` in the November 2025 OAuth
      // migration; only the loopback literals are permitted over plain http.
      // `flutter run -d chrome` serves on localhost by default, so without
      // this rewrite the derived web redirect URI would be one Spotify
      // rejects outright.
      test('localhost becomes the IPv4 loopback literal', () {
        expect(Env.loopbackHostFor('localhost'), '127.0.0.1');
        expect(Env.loopbackHostFor('LOCALHOST'), '127.0.0.1');
        expect(Env.loopbackHostFor('localhost.localdomain'), '127.0.0.1');
      });

      test('loopback literals are left alone', () {
        expect(Env.loopbackHostFor('127.0.0.1'), '127.0.0.1');
        expect(Env.loopbackHostFor('::1'), '::1');
      });

      test('real hosts are left alone', () {
        expect(Env.loopbackHostFor('aurix.example.com'), 'aurix.example.com');
      });
    });

    group('random dev-server ports', () {
      // `flutter run -d chrome` with no --web-port (which is what the IDE run
      // buttons do) takes an OS-assigned port. The redirect URI then differs
      // on every launch, so no dashboard entry can match and Spotify answers
      // "redirect_uri: Not matching configuration".
      test('the OS dynamic range is recognised', () {
        expect(Env.isEphemeralPort(51066), isTrue);
        expect(Env.isEphemeralPort(49152), isTrue);
        expect(Env.isEphemeralPort(65535), isTrue);
      });

      test('deliberately pinned ports are not flagged', () {
        expect(Env.isEphemeralPort(8080), isFalse);
        expect(Env.isEphemeralPort(3000), isFalse);
        expect(Env.isEphemeralPort(5000), isFalse);
        expect(Env.isEphemeralPort(443), isFalse);
      });

      test('the warning is silent off the web', () {
        expect(Env.webRedirectUriWarning, isNull);
      });
    });

    test('the web callback path matches the shipped page', () {
      // web/auth.html is what Spotify redirects to; renaming one without the
      // other breaks web sign-in with a 404 the user never sees.
      expect(Env.webCallbackPath, 'auth.html');
    });

    group('a pinned web redirect URI', () {
      tearDown(Env.resetForTesting);

      test('is used verbatim, without deriving anything', () {
        Env.loadFromString(
          'SPOTIFY_REDIRECT_URI_WEB=http://127.0.0.1:8080/auth.html\n',
        );
        expect(Env.webRedirectUri, 'http://127.0.0.1:8080/auth.html');
      });

      test('yields the origin the plugin must expect a postMessage from', () {
        Env.loadFromString(
          'SPOTIFY_REDIRECT_URI_WEB=http://127.0.0.1:8080/auth.html\n',
        );
        // Path stripped, port kept — this is what is handed to
        // FlutterWebAuth2Options.debugOrigin.
        expect(Env.webRedirectOrigin, 'http://127.0.0.1:8080');
      });

      test('drops the default port from the origin', () {
        Env.loadFromString(
          'SPOTIFY_REDIRECT_URI_WEB=https://aurix.example.com/auth.html\n',
        );
        expect(Env.webRedirectOrigin, 'https://aurix.example.com');
      });

      test('an unparseable value yields no origin rather than a bad one', () {
        Env.loadFromString('SPOTIFY_REDIRECT_URI_WEB=not a url\n');
        expect(Env.webRedirectOrigin, isEmpty);
      });
    });

    group('ephemeral port detection', () {
      test('the OS dynamic range is recognised', () {
        // The range `flutter run -d chrome` draws from when --web-port is
        // omitted. 51066 is the port from the reported failure.
        expect(Env.isEphemeralPort(51066), isTrue);
        expect(Env.isEphemeralPort(49152), isTrue);
        expect(Env.isEphemeralPort(65535), isTrue);
      });

      test('a pinned dev port is not', () {
        expect(Env.isEphemeralPort(8080), isFalse);
        expect(Env.isEphemeralPort(3000), isFalse);
        expect(Env.isEphemeralPort(443), isFalse);
      });
    });

    group('loopback sibling origins', () {
      // A browser treats these as different origins even though they are the
      // same machine, which is what silently breaks the postMessage handoff.
      test('localhost and 127.0.0.1 on the same port are siblings', () {
        expect(
          Env.isLoopbackSiblingOrigin(
            'http://127.0.0.1:8080',
            'http://localhost:8080',
          ),
          isTrue,
        );
      });

      test('a different port is not a sibling, it is a mismatch', () {
        expect(
          Env.isLoopbackSiblingOrigin(
            'http://127.0.0.1:8080',
            'http://localhost:51066',
          ),
          isFalse,
        );
      });

      test('an identical origin is not a sibling', () {
        expect(
          Env.isLoopbackSiblingOrigin(
            'http://127.0.0.1:8080',
            'http://127.0.0.1:8080',
          ),
          isFalse,
        );
      });

      test('a remote host is never a sibling of loopback', () {
        expect(
          Env.isLoopbackSiblingOrigin(
            'http://127.0.0.1:8080',
            'http://192.168.0.6:8080',
          ),
          isFalse,
        );
      });
    });
  });

  group('Auth proxy', () {
    tearDown(Env.resetForTesting);

    test('is off by default, which is correct for PKCE', () {
      Env.loadFromString('SPOTIFY_CLIENT_ID=x\n');
      expect(Env.authProxyBaseUrl, isEmpty);
      expect(Env.usesAuthProxy, isFalse);
      expect(Env.authProxyProblem, isNull);
    });

    test('the mobile-specific key wins over the shared one on native', () {
      // `flutter test` runs on the VM, so this exercises the native branch.
      Env.loadFromString(
        'AUTH_PROXY_BASE_URL=http://127.0.0.1:8787\n'
        'AUTH_PROXY_BASE_URL_MOBILE=http://192.168.0.6:8787\n',
      );
      expect(Env.authProxyBaseUrl, 'http://192.168.0.6:8787');
      // A LAN address is the right answer on a device, so no complaint.
      expect(Env.authProxyProblem, isNull);
    });

    test('falls back to the shared key when no platform key is set', () {
      Env.loadFromString('AUTH_PROXY_BASE_URL=https://proxy.example.com\n');
      expect(Env.authProxyBaseUrl, 'https://proxy.example.com');
      expect(Env.authProxyProblem, isNull);
    });

    test('warns when a native build is pointed at loopback', () {
      // The trap this exists for: on a physical phone, 127.0.0.1 is the phone.
      // The request never reaches the development machine.
      Env.loadFromString('AUTH_PROXY_BASE_URL=http://127.0.0.1:8787\n');
      final problem = Env.authProxyProblem;
      expect(problem, isNotNull);
      expect(problem, contains('loopback is the device itself'));
      expect(problem, contains('0.0.0.0'));
    });

    test('a non-URL value is ignored rather than used', () {
      Env.loadFromString('AUTH_PROXY_BASE_URL=localhost:8787\n');
      expect(Env.authProxyBaseUrl, isEmpty);
      expect(Env.usesAuthProxy, isFalse);
      expect(Env.authProxyProblem, contains('not an absolute http(s) URL'));
    });

    group('loopback host detection', () {
      test('recognises every spelling of "this machine"', () {
        expect(Env.isLoopbackHost('127.0.0.1'), isTrue);
        expect(Env.isLoopbackHost('127.0.0.53'), isTrue);
        expect(Env.isLoopbackHost('localhost'), isTrue);
        expect(Env.isLoopbackHost('LOCALHOST'), isTrue);
        expect(Env.isLoopbackHost('::1'), isTrue);
      });

      test('a LAN address is not loopback', () {
        expect(Env.isLoopbackHost('192.168.0.6'), isFalse);
        // The emulator's alias for the host machine is reachable, not loopback.
        expect(Env.isLoopbackHost('10.0.2.2'), isFalse);
        expect(Env.isLoopbackHost('proxy.example.com'), isFalse);
      });
    });
  });

  // The `ExplicitContentPolicy` group that used to live here is gone with the
  // class. It reconciled Spotify's account-level explicit-content filter with
  // the in-app preference, and distinguished three authorities: filtered by the
  // account, locked by the account, and unknown. An AURIX account has no such
  // filter, so the preference is simply the user's and there is nothing left to
  // reconcile — see `settings_screen.dart`.

  group('AURIX API configuration', () {
    setUp(Env.resetForTesting);
    tearDown(Env.resetForTesting);

    test('is what gates the app, not the Spotify credentials', () {
      Env.loadFromString('AURIX_API_BASE_URL=https://api.example.com\n');
      expect(Env.isApiConfigured, isTrue);
      expect(Env.isConfigured, isTrue, reason: 'the API alone is enough');
      // Spotify absent is a fully working app minus one optional menu item.
      expect(Env.isSpotifyConfigured, isFalse);
    });

    test('names the key that is missing', () {
      Env.loadFromString('SPOTIFY_CLIENT_ID=abc\n');
      final hint = Env.apiConfigurationHint;
      expect(hint, contains('AURIX_API_BASE_URL'));
      // The hint has to be actionable on its own — the emulator address is the
      // single most common first-run mistake, so it names it.
      expect(hint, contains('10.0.2.2'));
    });

    test('strips a trailing slash and an /api/v1 suffix from the base URL', () {
      // Pasting the full API root into configuration is the obvious mistake to
      // make: the version prefix is owned by AurixEndpoints, so leaving it here
      // would produce /api/v1/api/v1/auth/login.
      Env.loadFromString('AURIX_API_BASE_URL=https://api.example.com/api/v1/\n');
      expect(Env.apiBaseUrl, 'https://api.example.com');
    });

    test('does not flag localhost as insecure, but does flag a real host', () {
      // Every request carries a bearer token. http is fine against a loopback
      // address and is a genuine problem anywhere else.
      Env.loadFromString('AURIX_API_BASE_URL=http://localhost:4000\n');
      expect(Env.isApiInsecure, isFalse);

      Env.resetForTesting();
      Env.loadFromString('AURIX_API_BASE_URL=http://10.0.2.2:4000\n');
      expect(Env.isApiInsecure, isFalse, reason: 'the Android emulator host');

      Env.resetForTesting();
      Env.loadFromString('AURIX_API_BASE_URL=http://api.example.com\n');
      expect(Env.isApiInsecure, isTrue);

      Env.resetForTesting();
      Env.loadFromString('AURIX_API_BASE_URL=https://api.example.com\n');
      expect(Env.isApiInsecure, isFalse);
    });

    test('carries no MongoDB configuration at all', () {
      // The property the whole migration rests on. A connection string
      // compiled into a mobile binary is a connection string published to
      // everyone who installs it, so Env must have no way to read one — not
      // from .env, not from a --dart-define.
      Env.loadFromString(
        'MONGODB_URI=mongodb+srv://user:pass@cluster.example.com/db\n'
        'AURIX_API_BASE_URL=https://api.example.com\n',
      );
      expect(Env.debugSummary, isNot(contains('mongodb')));
      expect(Env.debugSummary, isNot(contains('pass')));
    });

    test('the boot summary names the API first', () {
      Env.loadFromString('AURIX_API_BASE_URL=https://api.example.com\n');
      // Spotify is printed as an import provider, not as the app's identity:
      // a build with "<none>" there is fully functional.
      expect(Env.debugSummary, contains('api=https://api.example.com'));
      expect(Env.debugSummary, contains('spotify_import=<none>'));
    });
  });
}
