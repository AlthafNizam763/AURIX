import '../constants/aurix_endpoints.dart';

/// Which deployment of the AURIX API this build talks to.
///
/// The switch itself is one value — `AURIX_ENV` — read by [Env.apiEnvironment].
/// Everything that differs between the two deployments is a constant below, so
/// moving an app between them is a one-line change and never a search through
/// service files for a URL somebody pasted.
enum ApiEnvironment {
  /// The Next.js app in `web/`, run locally with `npm run dev`.
  development,

  /// The Vercel deployment.
  production,
}

/// The addresses of the AURIX backend, and the rules for choosing between them.
///
/// ## Why this holds *origins* rather than full API roots
///
/// The `/api/v1` prefix is owned by [AurixEndpoints.prefix] — every endpoint
/// constant carries it — so the client's `baseUrl` must stop at the origin or
/// requests would go to `/api/v1/api/v1/auth/login`. [apiRootFor] composes the
/// two when the full root is what is wanted (a log line, a diagnostic screen),
/// and [normaliseOrigin] absorbs the obvious configuration mistake of pasting
/// the full root into `AURIX_API_BASE_URL`.
///
/// ## Nothing here is a secret
///
/// These are the addresses of a public HTTP service that authenticates every
/// request it serves. The database credentials live in `web/.env.local` and are
/// never in this process — see the note in `env.dart`.
abstract final class ApiConfig {
  // ---- Production ---------------------------------------------------------

  /// The deployed AURIX backend. Origin only; see the class note.
  static const String productionOrigin = 'https://aurix-iota-tawny.vercel.app';

  /// The production API root — `https://…/api/v1`.
  static const String productionBaseUrl = '$productionOrigin${AurixEndpoints.prefix}';

  // ---- Development --------------------------------------------------------

  /// `npm run dev` in `web/` listens here.
  static const String developmentOrigin = 'http://localhost:3000';

  /// The Android emulator reaches the host machine at `10.0.2.2`; `localhost`
  /// there is the emulated device itself, and pointing at it produces a
  /// connection error that reads like a dead server.
  static const String developmentAndroidOrigin = 'http://10.0.2.2:3000';

  /// The development API root, for messages and diagnostics.
  static const String developmentBaseUrl = '$developmentOrigin${AurixEndpoints.prefix}';

  /// The origin to use for [environment] on this platform, when no explicit
  /// `AURIX_API_BASE_URL` was given.
  ///
  /// A physical device is deliberately not special-cased: no constant can know
  /// the host machine's LAN address, so that case stays an explicit
  /// `AURIX_API_BASE_URL=http://192.168.x.y:3000`.
  static String defaultOrigin(
    ApiEnvironment environment, {
    required bool isWeb,
    required bool isAndroid,
  }) => switch (environment) {
    // One address serves every platform in production — there is no loopback
    // ambiguity to resolve once the backend is on the public internet.
    ApiEnvironment.production => productionOrigin,
    ApiEnvironment.development =>
      isAndroid && !isWeb ? developmentAndroidOrigin : developmentOrigin,
  };

  /// Parses the `AURIX_ENV` setting. Null for anything unrecognised — including
  /// an empty value — so the caller decides what "not set" means rather than
  /// silently getting one of the two deployments.
  static ApiEnvironment? parseEnvironment(String raw) =>
      switch (raw.trim().toLowerCase()) {
        'production' || 'prod' || 'release' => ApiEnvironment.production,
        'development' || 'dev' || 'local' || 'debug' => ApiEnvironment.development,
        _ => null,
      };

  /// Trailing slashes removed, and a trailing `/api/v1` stripped.
  ///
  /// Pasting the full API root into configuration is the obvious mistake to
  /// make, and the resulting `/api/v1/api/v1/...` is a 404 that looks like a
  /// missing endpoint. It is absorbed rather than diagnosed.
  static String normaliseOrigin(String value) {
    var out = value.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    if (out.endsWith(AurixEndpoints.prefix)) {
      out = out.substring(0, out.length - AurixEndpoints.prefix.length);
    }
    // A base URL that ended in `/api/v1/` leaves a trailing slash behind.
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  /// `<origin>/api/v1` — the full API root. Empty in, empty out, so an
  /// unconfigured build does not produce a URL that looks usable.
  static String apiRootFor(String origin) =>
      origin.isEmpty ? '' : '$origin${AurixEndpoints.prefix}';
}
