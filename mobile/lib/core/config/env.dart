import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration for AURIX.
///
/// Values are resolved in priority order:
///   1. `--dart-define=KEY=value` (preferred for CI / release builds)
///   2. the bundled `.env` asset (preferred for local development)
///   3. a safe built-in default, where one exists
///
/// There is deliberately no `clientSecret`. AURIX authenticates with the
/// Authorization Code + PKCE flow, which is the flow Spotify documents for
/// public clients such as mobile apps. PKCE proves possession of a
/// per-request secret that never leaves the device, so no long-lived secret is
/// ever compiled into the APK/IPA.
abstract final class Env {
  static const _defineClientId = String.fromEnvironment('SPOTIFY_CLIENT_ID');
  static const _defineRedirectUri = String.fromEnvironment('SPOTIFY_REDIRECT_URI');
  static const _defineWebRedirectUri = String.fromEnvironment('SPOTIFY_REDIRECT_URI_WEB');
  static const _defineAppRemoteRedirectUri =
      String.fromEnvironment('SPOTIFY_APP_REMOTE_REDIRECT_URI');
  static const _defineCallbackScheme = String.fromEnvironment('SPOTIFY_CALLBACK_SCHEME');
  static const _defineProxyBaseUrl = String.fromEnvironment('AUTH_PROXY_BASE_URL');
  static const _defineWebProxyBaseUrl =
      String.fromEnvironment('AUTH_PROXY_BASE_URL_WEB');
  static const _defineMobileProxyBaseUrl =
      String.fromEnvironment('AUTH_PROXY_BASE_URL_MOBILE');

  /// Filename of the web OAuth landing page shipped in `web/`.
  ///
  /// Must stay in step with the actual file: Spotify redirects the browser
  /// here, and the page hands the callback URL back to `flutter_web_auth_2`.
  static const String webCallbackPath = 'auth.html';

  static bool _dotEnvLoaded = false;

  /// Loads the `.env` asset if it is present.
  ///
  /// A missing or malformed `.env` is not fatal: builds driven entirely by
  /// `--dart-define` legitimately ship without one. Failure to configure is
  /// surfaced later through [isConfigured] so the UI can explain it, rather
  /// than crashing on startup with a stack trace.
  static Future<void> load() async {
    try {
      await dotenv.load(fileName: '.env');
      _dotEnvLoaded = true;
    } on Object catch (error) {
      _dotEnvLoaded = false;
      if (kDebugMode) {
        debugPrint('[Env] No .env asset loaded ($error). Falling back to --dart-define.');
      }
    }
  }

  /// Loads configuration from a literal `.env` body instead of the asset.
  ///
  /// Test-only. Without it, every configuration-dependent path — which is most
  /// of sign-in — could only be tested on a machine that happened to have a
  /// valid local `.env`, and `.env` is git-ignored.
  @visibleForTesting
  static void loadFromString(String contents) {
    dotenv.loadFromString(envString: contents);
    _dotEnvLoaded = true;
  }

  /// Drops anything [loadFromString] put in place. Test-only.
  @visibleForTesting
  static void resetForTesting() {
    dotenv.clean();
    _dotEnvLoaded = false;
  }

  static String _read(String key, String fromDefine, {String fallback = ''}) {
    if (fromDefine.isNotEmpty) return fromDefine;
    if (_dotEnvLoaded) {
      final value = dotenv.env[key];
      if (value != null && value.trim().isNotEmpty) return value.trim();
    }
    return fallback;
  }

  /// Spotify application Client ID. Public by design under PKCE.
  static String get spotifyClientId => _read('SPOTIFY_CLIENT_ID', _defineClientId);

  /// The redirect URI this build will actually send to Spotify.
  ///
  /// Platform-dependent by necessity, not by preference. A custom scheme is
  /// the right answer on a phone and an impossible one in a browser: nothing
  /// can redirect a browser tab to `aurix://auth-callback`, so on web the flow
  /// has to come back through a real `http(s)` URL that serves a page.
  ///
  /// **Both values must be registered in the Spotify dashboard** if both
  /// platforms are used — Spotify matches the redirect URI exactly, and an
  /// unregistered one is rejected before the user ever sees a login form.
  static String get spotifyRedirectUri =>
      kIsWeb ? webRedirectUri : nativeRedirectUri;

  /// The Android / iOS / desktop redirect URI. Always a custom scheme.
  static String get nativeRedirectUri => _read(
    'SPOTIFY_REDIRECT_URI',
    _defineRedirectUri,
    fallback: 'aurix://auth-callback',
  );

  /// The redirect URI handed to Spotify **App Remote**.
  ///
  /// Deliberately a different host from [nativeRedirectUri], and it must be
  /// registered in the dashboard as its own entry.
  ///
  /// Sharing `aurix://auth-callback` with the PKCE flow would put two
  /// activities in competition for one URI: `flutter_web_auth_2`'s
  /// `CallbackActivity`, which is mid-flight during sign-in, and the Spotify
  /// auth library's activity declared from the Gradle manifest placeholders.
  /// Android resolves that with a chooser or an arbitrary pick — the same
  /// class of bug as the deep-link/OAuth clash fixed in the manifest.
  ///
  /// Keeping them separate also means an App Remote authorization can never
  /// interfere with a sign-in that is already in progress.
  ///
  /// Must stay in step with `redirectSchemeName`/`redirectHostName` in
  /// android/app/build.gradle.kts.
  static String get appRemoteRedirectUri => _read(
    'SPOTIFY_APP_REMOTE_REDIRECT_URI',
    _defineAppRemoteRedirectUri,
    fallback: 'aurix://spotify-remote',
  );

  /// The Flutter Web redirect URI.
  ///
  /// Defaults to `<origin>/auth.html` for the origin the app is being served
  /// from, which is what makes `flutter run -d chrome --web-port=8080` work
  /// without editing anything. Set `SPOTIFY_REDIRECT_URI_WEB` to override it
  /// for a deployed build (or for any origin you would rather pin).
  ///
  /// Deliberately *not* hard-coded to a production URL: a wrong absolute URL
  /// here fails in the most confusing way there is — Spotify shows
  /// "INVALID_CLIENT: Invalid redirect URI" and never redirects back at all.
  static String get webRedirectUri {
    final explicit = _read('SPOTIFY_REDIRECT_URI_WEB', _defineWebRedirectUri);
    if (explicit.isNotEmpty) return explicit;
    return defaultWebRedirectUri;
  }

  /// `<scheme>://<host>[:<port>]/auth.html` for the current origin.
  ///
  /// Empty off the web, where `Uri.base` is a filesystem path rather than an
  /// origin and asking for one throws.
  ///
  /// `localhost` is rewritten to `127.0.0.1`, which is not cosmetic: Spotify
  /// stopped accepting `localhost` redirect URIs in the November 2025 OAuth
  /// migration and documents the loopback *literal* as the only permitted
  /// non-HTTPS form. `flutter run -d chrome` serves on `localhost` by default,
  /// so without this rewrite the generated URI would be one Spotify rejects
  /// outright — and it would be rejected on the authorize page, before any
  /// redirect, which is the hardest failure of the set to diagnose.
  /// See https://developer.spotify.com/documentation/web-api/concepts/redirect_uri
  static String get defaultWebRedirectUri {
    if (!kIsWeb) return '';
    final base = Uri.base;
    return Uri(
      scheme: base.scheme,
      host: loopbackHostFor(base.host),
      port: base.hasPort ? base.port : null,
      path: '/$webCallbackPath',
    ).toString();
  }

  /// Ports the operating system hands out at random.
  ///
  /// `flutter run -d chrome` — including the VS Code / Android Studio run
  /// buttons, which pass no port at all — takes one of these unless
  /// `--web-port` pins it. The derived redirect URI is then different on every
  /// launch, so no dashboard entry can ever match it.
  ///
  /// Visible for testing.
  static bool isEphemeralPort(int port) => port >= 49152 && port <= 65535;

  /// The origin of [webRedirectUri] — `http://127.0.0.1:8080` for the default
  /// configuration.
  ///
  /// This is what `flutter_web_auth_2` must be told to expect as the origin of
  /// the `postMessage` coming back from `auth.html`. Empty when the configured
  /// value is not a parseable absolute URL.
  static String get webRedirectOrigin {
    final uri = Uri.tryParse(webRedirectUri);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '';
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
  }

  /// True when [a] and [b] are the two spellings of the same loopback origin.
  ///
  /// `http://localhost:8080` and `http://127.0.0.1:8080` are the *same machine*
  /// but, to a browser, two different origins. That distinction is the single
  /// most confusing thing about local web OAuth: Spotify requires the literal
  /// `127.0.0.1`, while `flutter run -d chrome` serves on `localhost` unless
  /// `--web-hostname` says otherwise. The result is a redirect that lands on a
  /// page which then cannot talk back to the app that opened it.
  ///
  /// Visible for testing.
  static bool isLoopbackSiblingOrigin(String a, String b) {
    final left = Uri.tryParse(a);
    final right = Uri.tryParse(b);
    if (left == null || right == null) return false;
    if (left.scheme != right.scheme) return false;
    if (left.port != right.port) return false;
    return loopbackHostFor(left.host) == loopbackHostFor(right.host) &&
        left.host != right.host;
  }

  /// Non-null when this web build's redirect URI will not work as configured.
  ///
  /// Printed at boot rather than left to fail on Spotify's servers or, worse,
  /// to hang silently. Covers the three ways local web OAuth goes wrong, in
  /// the order they bite.
  static String? get webRedirectUriWarning {
    if (!kIsWeb) return null;

    final configured = _read('SPOTIFY_REDIRECT_URI_WEB', _defineWebRedirectUri);
    final actualOrigin = Uri.base.origin;

    // 1. Nothing pinned, and the dev server took a random port. The redirect
    //    URI changes every launch, so no dashboard entry can match it.
    if (configured.isEmpty) {
      final derived = defaultWebRedirectUri;
      final port = Uri.tryParse(derived)?.port ?? 0;
      if (!isEphemeralPort(port)) return null;

      return 'The dev server is on a random port ($port), so this build sends '
          'redirect_uri=$derived — a value that changes every launch and '
          'cannot be registered. Spotify will answer "redirect_uri: Not '
          'matching configuration". Pin it: set SPOTIFY_REDIRECT_URI_WEB in '
          '.env and run with --web-port 8080.';
    }

    final expectedOrigin = webRedirectOrigin;
    if (expectedOrigin.isEmpty || expectedOrigin == actualOrigin) return null;

    // 2. Pinned to the loopback sibling of where the app is actually served.
    //    Sign-in reaches auth.html and then stalls, because a browser treats
    //    localhost and 127.0.0.1 as different origins. AURIX handles this —
    //    auth.html posts to both loopback spellings and the auth call declares
    //    the expected origin — but it is worth saying out loud, because the
    //    localStorage fallback cannot cross origins and a stricter browser
    //    policy would break the postMessage path too.
    if (isLoopbackSiblingOrigin(expectedOrigin, actualOrigin)) {
      return 'Serving from $actualOrigin but redirecting to $expectedOrigin. '
          'Same machine, different browser origins. Sign-in is bridged across '
          'them and should still work; to remove the hop entirely, run with '
          '--web-hostname 127.0.0.1 --web-port 8080.';
    }

    // 3. Pinned to something else entirely — usually a stale port. Spotify
    //    redirects to a page that is not being served, and nothing comes back.
    return 'SPOTIFY_REDIRECT_URI_WEB points at $expectedOrigin but this build '
        'is served from $actualOrigin. Spotify will redirect to a page that '
        'is not running and sign-in will hang. Run with --web-port '
        '${Uri.tryParse(expectedOrigin)?.port ?? 8080}, or update '
        'SPOTIFY_REDIRECT_URI_WEB (and the dashboard) to match $actualOrigin.';
  }

  /// Maps the hostnames Spotify refuses onto the loopback literals it accepts.
  ///
  /// Visible for testing.
  static String loopbackHostFor(String host) {
    switch (host.toLowerCase()) {
      case 'localhost':
      case 'localhost.localdomain':
        return '127.0.0.1';
      // Dart renders an IPv6 host without brackets here; Uri adds them back.
      case '::1':
        return '::1';
      default:
        return host;
    }
  }

  /// Custom URL scheme used to capture the OAuth redirect on native platforms.
  ///
  /// Always derived from [nativeRedirectUri], never from the web one. On web
  /// `flutter_web_auth_2` ignores this value entirely (it matches on the
  /// window/`postMessage` handshake instead), but it still has to be a valid
  /// RFC 3986 scheme — and returning `http` here would push the plugin's
  /// *native* code paths into their https/App Links branch, which needs
  /// `httpsHost`/`httpsPath` and is not what this app uses.
  static String get spotifyCallbackScheme {
    final explicit = _read('SPOTIFY_CALLBACK_SCHEME', _defineCallbackScheme);
    if (explicit.isNotEmpty) return explicit;
    // Derive it from the native redirect URI so the two cannot drift apart.
    final scheme = Uri.tryParse(nativeRedirectUri)?.scheme ?? '';
    return scheme.isEmpty ? 'aurix' : scheme;
  }

  /// The raw, unvalidated proxy setting for this platform.
  ///
  /// A local development backend cannot have one address. `127.0.0.1` is the
  /// right answer in a browser on the host machine and the *wrong* one on a
  /// physical phone, where loopback is the phone itself — the request never
  /// leaves the device. A phone has to be given the host's LAN address.
  ///
  /// So the platform-specific keys win when present, and the shared
  /// `AUTH_PROXY_BASE_URL` remains the answer for deployments where one URL
  /// genuinely serves everything.
  static String get _rawAuthProxyBaseUrl {
    final platformSpecific = kIsWeb
        ? _read('AUTH_PROXY_BASE_URL_WEB', _defineWebProxyBaseUrl)
        : _read('AUTH_PROXY_BASE_URL_MOBILE', _defineMobileProxyBaseUrl);
    if (platformSpecific.isNotEmpty) return platformSpecific;
    return _read('AUTH_PROXY_BASE_URL', _defineProxyBaseUrl);
  }

  /// Optional token-exchange proxy. Empty means "talk to Spotify directly",
  /// which is the correct configuration for a PKCE public client.
  ///
  /// A value that is not an absolute `http(s)` URL is ignored rather than
  /// used: every OAuth call would otherwise be sent somewhere meaningless and
  /// fail as an opaque 404, which is a miserable thing to debug. See
  /// [authProxyProblem] for the message the boot log prints in that case.
  static String get authProxyBaseUrl {
    final raw = _rawAuthProxyBaseUrl;
    if (raw.isEmpty) return '';
    return _isAbsoluteHttpUrl(raw) ? raw : '';
  }

  static bool get usesAuthProxy => authProxyBaseUrl.isNotEmpty;

  /// Non-null when the proxy setting for this platform is unusable.
  static String? get authProxyProblem {
    final raw = _rawAuthProxyBaseUrl;
    if (raw.isEmpty) return null;

    if (!_isAbsoluteHttpUrl(raw)) {
      return 'The auth proxy base URL is not an absolute http(s) URL ("$raw") '
          '— ignoring it and talking to accounts.spotify.com directly.';
    }

    // A loopback proxy on a phone or emulator resolves to the device, not to
    // the machine running the backend. The request fails as "connection
    // refused", which reads like the backend is down rather than unreachable.
    if (!kIsWeb && isLoopbackHost(Uri.parse(raw).host)) {
      return 'The auth proxy is set to $raw, but on a physical device '
          'loopback is the device itself — not the computer running the '
          'backend. Set AUTH_PROXY_BASE_URL_MOBILE to the host machine\'s LAN '
          'address (for example http://192.168.0.6:<port>), make sure the '
          'backend listens on 0.0.0.0 rather than 127.0.0.1, and allow the '
          'port through the host firewall.';
    }

    return null;
  }

  /// True for the addresses that mean "this machine".
  ///
  /// Visible for testing.
  static bool isLoopbackHost(String host) {
    final normalised = host.toLowerCase();
    return normalised == 'localhost' ||
        normalised == 'localhost.localdomain' ||
        normalised == '127.0.0.1' ||
        normalised == '::1' ||
        normalised.startsWith('127.');
  }

  static bool _isAbsoluteHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        uri.hasScheme &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  // -------------------------------------------------------------------------
  // The AURIX API — the backend
  // -------------------------------------------------------------------------
  //
  // AURIX's persistent data lives in MongoDB, and the app never touches MongoDB
  // directly. It talks to the AURIX API in `server/`, which holds the database
  // credentials and is the only process that can reach the cluster.
  //
  // That indirection is the whole security model and is worth stating plainly:
  // a connection string compiled into a mobile binary is a connection string
  // published to everyone who installs it, and no amount of obfuscation changes
  // that. `MONGODB_URI` therefore appears in `server/.env` and appears nowhere
  // in this repository's Flutter half — not in `.env`, not in a `--dart-define`,
  // not in a constant.
  //
  // What *is* configured here is a URL. It is not a secret; it is the address
  // of a public HTTP service that authenticates every request it serves.

  static const _defineApiBaseUrl = String.fromEnvironment('AURIX_API_BASE_URL');
  static const _defineApiBaseUrlWeb =
      String.fromEnvironment('AURIX_API_BASE_URL_WEB');
  static const _defineApiBaseUrlAndroid =
      String.fromEnvironment('AURIX_API_BASE_URL_ANDROID');

  /// Where the AURIX API is.
  ///
  /// Platform-specific keys are consulted first, because "localhost" means
  /// three different things during development and getting it wrong produces a
  /// connection error that looks like a dead server:
  ///
  ///  * On the **Android emulator**, the host machine is `10.0.2.2` —
  ///    `localhost` is the emulated device itself.
  ///  * On **web**, `localhost` is the browser's own machine, which is usually
  ///    right.
  ///  * On a **physical device** neither works, and the LAN address has to be
  ///    set explicitly.
  ///
  /// ## There is deliberately no built-in default
  ///
  /// Not even in debug. A silent fallback to `http://localhost:4000` was the
  /// obvious convenience and it is the wrong trade: it makes [isConfigured]
  /// permanently true, which means the setup screen — the one surface that
  /// tells a developer *what to add and where* — becomes unreachable on exactly
  /// the build where it is needed. What they would get instead is a connection
  /// error three screens later.
  ///
  /// `.env.example` carries the local values, so copying it is the one step
  /// this replaces.
  static String get apiBaseUrl {
    final platformValue = kIsWeb
        ? _read('AURIX_API_BASE_URL_WEB', _defineApiBaseUrlWeb)
        : defaultTargetPlatform == TargetPlatform.android
        ? _read('AURIX_API_BASE_URL_ANDROID', _defineApiBaseUrlAndroid)
        : '';
    if (platformValue.isNotEmpty) return _normaliseBaseUrl(platformValue);

    final shared = _read('AURIX_API_BASE_URL', _defineApiBaseUrl);
    return shared.isEmpty ? '' : _normaliseBaseUrl(shared);
  }

  /// Trailing slashes removed, and the `/api/v1` suffix stripped if present.
  ///
  /// The version prefix is owned by the client — every endpoint constant in
  /// `AurixEndpoints` carries it — so a base URL that already ends in `/api/v1`
  /// would produce `/api/v1/api/v1/auth/login`. Pasting the full API root into
  /// this field is the obvious mistake to make, so it is absorbed rather than
  /// diagnosed.
  static String _normaliseBaseUrl(String value) {
    var out = value.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    if (out.endsWith('/api/v1')) out = out.substring(0, out.length - '/api/v1'.length);
    return out;
  }

  /// True when this build knows where its backend is.
  ///
  /// This — not [isSpotifyConfigured] — is what gates the app. AURIX is a
  /// client of its own API; Spotify is an optional import provider whose
  /// absence costs the user one menu item and nothing else.
  static bool get isApiConfigured => apiBaseUrl.isNotEmpty;

  /// True when the API is reached over plaintext HTTP.
  ///
  /// Fine against localhost, and a real problem anywhere else: every request
  /// carries a bearer token, and a token on an unencrypted connection is a
  /// token anyone on the network has. Surfaced at boot rather than enforced,
  /// because a LAN address during development is a legitimate reason to be on
  /// http.
  static bool get isApiInsecure {
    final uri = Uri.tryParse(apiBaseUrl);
    if (uri == null || uri.scheme != 'http') return false;
    return uri.host != 'localhost' && uri.host != '127.0.0.1' && uri.host != '10.0.2.2';
  }

  /// What is missing before the app can reach its backend, for the setup screen.
  static String get apiConfigurationHint {
    if (isApiConfigured) return '';
    return 'Missing configuration: AURIX_API_BASE_URL. Start the API with '
        '`cd server && npm install && npm start`, then set the URL in .env — '
        'http://localhost:4000 for web and desktop, http://10.0.2.2:4000 for '
        'the Android emulator, or http://<your-lan-ip>:4000 for a physical '
        'device. See server/.env.example for the database side.';
  }

  // -------------------------------------------------------------------------
  // Social sign-in — where the browser comes back to
  // -------------------------------------------------------------------------
  //
  // ## There is no client id here, and there is certainly no client secret
  //
  // Compare the Spotify block above, which carries a client id because the app
  // itself runs that OAuth flow. AURIX's own social sign-in works the other way
  // round: the app asks the API to start the flow, the browser goes to Google,
  // Google returns to *the API*, and the API — holding the client secret —
  // trades the code for a token and hands the app a single-use AURIX grant.
  //
  // So the only thing this build needs to know is the address the API should
  // send the browser back to at the very end. That address is not a secret; it
  // is a URI this application has registered with the operating system.
  //
  // It must also appear in the API's `OAUTH_APP_REDIRECTS` allow-list. That is
  // not duplication for its own sake: the final hop puts a one-time credential
  // in a URL, and a server that redirected wherever it was asked to would be
  // an open redirector with a session attached.

  static const _defineLoginRedirectUri =
      String.fromEnvironment('AURIX_LOGIN_REDIRECT_URI');
  static const _defineLoginRedirectUriWeb =
      String.fromEnvironment('AURIX_LOGIN_REDIRECT_URI_WEB');

  /// Where the AURIX API returns the browser after a social sign-in.
  static String get loginRedirectUri =>
      kIsWeb ? loginWebRedirectUri : loginNativeRedirectUri;

  /// The Android / iOS / desktop value. Always a custom scheme.
  ///
  /// Deliberately a different host from [nativeRedirectUri] and
  /// [appRemoteRedirectUri]. Sharing `aurix://auth-callback` with the Spotify
  /// import flow would put two pending authorizations in competition for one
  /// URI, and Android resolves that with a chooser or an arbitrary pick — the
  /// same clash the manifest notes already warn about.
  ///
  /// Must stay in step with the `CallbackActivity` intent filter in
  /// android/app/src/main/AndroidManifest.xml.
  static String get loginNativeRedirectUri => _read(
    'AURIX_LOGIN_REDIRECT_URI',
    _defineLoginRedirectUri,
    fallback: 'aurix://login-callback',
  );

  /// The Flutter Web value.
  ///
  /// Falls back to the same `auth.html` bridge page the Spotify flow uses.
  /// Sharing it is safe — the page does nothing but hand the callback URL back
  /// to whichever `flutter_web_auth_2` call is waiting, and only one can be.
  static String get loginWebRedirectUri {
    final explicit = _read('AURIX_LOGIN_REDIRECT_URI_WEB', _defineLoginRedirectUriWeb);
    if (explicit.isNotEmpty) return explicit;
    return defaultWebRedirectUri;
  }

  /// The scheme `flutter_web_auth_2` listens on for the callback.
  ///
  /// Derived from [loginNativeRedirectUri] rather than configured separately,
  /// so the two cannot drift. On web the plugin ignores it and matches on the
  /// window handshake instead, but it still has to be a valid RFC 3986 scheme.
  static String get loginCallbackScheme {
    final scheme = Uri.tryParse(loginNativeRedirectUri)?.scheme ?? '';
    return scheme.isEmpty ? 'aurix' : scheme;
  }

  /// True when the *app* is configured. The API is the only hard requirement.
  static bool get isConfigured => isApiConfigured;

  /// Human-readable explanation of what is missing, for the setup screen.
  static String get configurationHint => apiConfigurationHint;

  /// True when a Spotify **import** can be attempted.
  ///
  /// Gates one optional feature — the Import Music → Spotify flow — and nothing
  /// else. A build with no Spotify credentials is fully functional; it loses a
  /// menu item.
  static bool get isSpotifyConfigured =>
      spotifyClientId.isNotEmpty && spotifyRedirectUri.isNotEmpty;

  // -------------------------------------------------------------------------
  // YouTube — a second optional import provider
  // -------------------------------------------------------------------------
  //
  // Declared before the provider is implemented, deliberately: the point of
  // adding YouTube to the codebase now is to check that a second import source
  // needs nothing from the core, and configuration is part of that check. See
  // `YouTubeImportProvider`.

  static const _defineYouTubeClientId = String.fromEnvironment('YOUTUBE_CLIENT_ID');
  static const _defineYouTubeRedirectUri =
      String.fromEnvironment('YOUTUBE_REDIRECT_URI');
  static const _defineYouTubeApiKey = String.fromEnvironment('YOUTUBE_API_KEY');

  /// Google API key for the YouTube Data API v3.
  ///
  /// This — not [youTubeClientId] — is what a link import needs. Pasting a
  /// public playlist URL reads public data, and public data is what an API key
  /// reaches; requiring a Google sign-in first would be friction with nothing
  /// behind it.
  ///
  /// Not a secret in the sense a client secret is: it identifies the Cloud
  /// project for quota accounting and authorises nothing on its own. It is
  /// still worth restricting in the Cloud console (API restriction: YouTube
  /// Data API v3; application restriction: your Android/iOS app) so that a key
  /// lifted from the binary cannot be used to spend this project's quota.
  static String get youTubeApiKey =>
      _read('YOUTUBE_API_KEY', _defineYouTubeApiKey);

  /// Google OAuth client id, from a Cloud project with the YouTube Data API
  /// enabled. Public under PKCE, like Spotify's.
  ///
  /// Only needed for a user's **private** playlists, which require
  /// `youtube.readonly` and the user's own consent. Public playlist import —
  /// which is what pasting a link does — needs [youTubeApiKey] and nothing
  /// else.
  static String get youTubeClientId =>
      _read('YOUTUBE_CLIENT_ID', _defineYouTubeClientId);

  static String get youTubeRedirectUri => _read(
    'YOUTUBE_REDIRECT_URI',
    _defineYouTubeRedirectUri,
    fallback: 'aurix://youtube-callback',
  );

  /// True when a YouTube **link** import can be attempted.
  ///
  /// Deliberately gated on the API key alone. The OAuth client is a separate,
  /// later capability — gating link import on it would disable a working
  /// feature for a credential it does not use.
  static bool get isYouTubeConfigured => youTubeApiKey.isNotEmpty;

  /// True when a user's private YouTube playlists could be read.
  static bool get isYouTubeOAuthConfigured =>
      youTubeClientId.isNotEmpty && youTubeRedirectUri.isNotEmpty;

  static String get youTubeConfigurationHint {
    if (isYouTubeConfigured) return '';
    return 'Missing configuration: YOUTUBE_API_KEY. Create an API key in a '
        'Google Cloud project with the YouTube Data API v3 enabled, then add '
        'it to .env.';
  }

  /// What is missing before a Spotify import can run.
  static String get spotifyConfigurationHint {
    final missing = <String>[
      if (spotifyClientId.isEmpty) 'SPOTIFY_CLIENT_ID',
      if (spotifyRedirectUri.isEmpty)
        kIsWeb ? 'SPOTIFY_REDIRECT_URI_WEB' : 'SPOTIFY_REDIRECT_URI',
    ];
    if (missing.isEmpty) return '';
    return 'Missing configuration: ${missing.join(', ')}. '
        'Copy .env.example to .env and fill in the values from '
        'https://developer.spotify.com/dashboard';
  }

  /// The one-line instruction for registering this build's redirect URI.
  ///
  /// Shown on the sign-in failure path because a rejected redirect URI is by
  /// far the most common first-run problem, and the fix is a copy-paste into
  /// a dashboard field — provided you know the exact string to paste.
  static String get redirectUriRegistrationHint =>
      'Add this exact Redirect URI to your Spotify app '
      '(Dashboard → Settings → Edit → Redirect URIs): $spotifyRedirectUri';

  /// One line naming which backend and which Spotify application this build
  /// will use, printed at boot in debug.
  ///
  /// Worth the few lines of code. Two of the most common first-run failures
  /// are answered by it before they are investigated: "the app cannot reach
  /// anything" is usually an `AURIX_API_BASE_URL` pointing at `localhost` from
  /// an Android emulator, and a 403 from the Spotify Web API is an
  /// authorization decision Spotify makes per *application*, so the first
  /// question is always "which app am I running as?".
  ///
  /// Nothing secret is printed. The API base URL is a public address and the
  /// Spotify Client ID is public under PKCE — and the MongoDB credentials are
  /// not in this process at all, which is the point of the architecture.
  static String get debugSummary {
    final source = _dotEnvLoaded ? '.env' : '--dart-define';
    final clientId = spotifyClientId.isEmpty ? '<none>' : spotifyClientId;
    final tokenHost = usesAuthProxy ? authProxyBaseUrl : 'accounts.spotify.com';
    final redirect = spotifyRedirectUri.isEmpty ? '<none>' : spotifyRedirectUri;
    final api = apiBaseUrl.isEmpty ? '<missing>' : apiBaseUrl;
    // The platform is worth naming because both the API default and the
    // redirect URI differ by it, and "works on Android, fails on web" is
    // otherwise a mystery.
    //
    // The API comes first because it is the backend. Spotify is printed as
    // `spotify_import=` rather than as the app's identity, because that is all
    // it is — a build with `<none>` there is fully functional.
    return 'config[$source] platform=${kIsWeb ? 'web' : 'native'} '
        'api=$api '
        'spotify_import=$clientId redirect=$redirect token_endpoint=$tokenHost';
  }
}
