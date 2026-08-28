import { config as loadDotenv } from 'dotenv';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

// `server/.env`, resolved from this file rather than from the working
// directory. `npm start` run from the repo root and from `server/` must load
// the same file, and process.cwd() differs between the two.
const here = path.dirname(fileURLToPath(import.meta.url));
loadDotenv({ path: path.resolve(here, '../../.env'), quiet: true });

/**
 * Runtime configuration for the AURIX API.
 *
 * Everything secret lives here and nowhere else. The one rule this module
 * exists to enforce: **no secret is ever sent to a client.** The Mongo
 * connection string, the JWT signing keys and the SMTP password are read from
 * the process environment, used inside this process, and never appear in a
 * response body — not in an error, not in a health check, not in the admin
 * panel's bootstrap payload.
 *
 * Missing configuration fails at boot rather than on the first request. A
 * server that starts without a database URI and then 500s on every call is
 * strictly worse than one that refuses to start and says which key is absent.
 */

const required = [];

function read(key, { fallback, secret = false, required: isRequired = false } = {}) {
  const raw = process.env[key];
  const value = raw === undefined || raw.trim() === '' ? fallback : raw.trim();
  if (isRequired && (value === undefined || value === '')) required.push(key);
  return { key, value, secret };
}

function int(key, fallback) {
  const raw = process.env[key];
  const parsed = Number.parseInt(raw ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function bool(key, fallback) {
  const raw = process.env[key];
  if (raw === undefined || raw.trim() === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(raw.trim().toLowerCase());
}

const nodeEnv = process.env.NODE_ENV ?? 'development';
const isProduction = nodeEnv === 'production';

const mongoUri = read('MONGODB_URI', { secret: true, required: true }).value;
const jwtSecret = read('JWT_SECRET', { secret: true, required: true }).value;
const refreshSecret = read('JWT_REFRESH_SECRET', {
  secret: true,
  // Falls back to a *derived* key rather than to the access-token key itself,
  // so a deployment that sets only JWT_SECRET still cannot have a refresh
  // token accepted where an access token is expected.
  fallback: jwtSecret ? `${jwtSecret}::refresh` : undefined,
  required: true,
}).value;

if (required.length > 0) {
  const names = [...new Set(required)].join(', ');
  throw new Error(
    `AURIX API cannot start: missing required environment ${required.length > 1 ? 'variables' : 'variable'} ${names}. ` +
      'Copy server/.env.example to server/.env and fill them in.',
  );
}

export const env = {
  nodeEnv,
  isProduction,
  port: int('PORT', 4000),
  host: process.env.HOST ?? '0.0.0.0',

  // ---- Database ---------------------------------------------------------
  mongoUri,
  dbName: process.env.MONGODB_DB?.trim() || 'aurix',

  /**
   * DNS resolvers to use for the `mongodb+srv://` lookup, if the default one
   * cannot do it.
   *
   * An `mongodb+srv://` URI is not an address — it is an instruction to look up
   * a DNS **SRV** record and connect to whatever hosts it names. The driver does
   * that with `dns.resolveSrv`, which talks to a DNS server directly on port 53
   * rather than going through the operating system's resolver.
   *
   * A surprising number of networks break that specific path while ordinary
   * browsing works perfectly: corporate DNS that answers A records and refuses
   * SRV, a VPN capturing port 53, a router whose resolver rejects anything
   * unusual. The symptom is `querySrv ECONNREFUSED`, which is reported by the
   * MongoDB driver and therefore reads like a database problem — it is not, and
   * it happens before a single byte reaches Atlas.
   *
   * Setting this calls `dns.setServers()` at boot, which affects `resolve*` —
   * the SRV path — and deliberately **not** `dns.lookup`, so ordinary outbound
   * connections keep using the machine's own configuration.
   *
   * Empty means "use whatever this machine is configured with", which is right
   * almost everywhere. `npm run check-dns` says whether it is right here.
   */
  dnsServers: (process.env.DNS_SERVERS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  // ---- Tokens -----------------------------------------------------------
  jwtSecret,
  refreshSecret,
  accessTokenTtl: process.env.ACCESS_TOKEN_TTL?.trim() || '30m',
  refreshTokenDays: int('REFRESH_TOKEN_DAYS', 60),
  // Password-reset and email-verification links.
  actionTokenMinutes: int('ACTION_TOKEN_MINUTES', 60),

  // ---- CORS -------------------------------------------------------------
  // A comma-separated allow-list. Empty means "reflect the request origin",
  // which is right for local development and wrong for production — hence the
  // boot warning in index.js when this is empty and NODE_ENV is production.
  corsOrigins: (process.env.CORS_ORIGINS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  // ---- Uploads ----------------------------------------------------------
  maxLogoBytes: int('MAX_LOGO_BYTES', 2 * 1024 * 1024),
  maxFontBytes: int('MAX_FONT_BYTES', 4 * 1024 * 1024),

  // ---- Admin bootstrap --------------------------------------------------
  // The email that is granted `isAdmin` on registration, so a fresh
  // deployment has exactly one way to get its first administrator without a
  // shell. Everything after that is done by an existing admin through the API.
  bootstrapAdminEmail: (process.env.BOOTSTRAP_ADMIN_EMAIL ?? '').trim().toLowerCase(),

  // ---- Mail (optional) --------------------------------------------------
  // Absent SMTP is a supported configuration, not a broken one: password-reset
  // and verification tokens are then logged by the server and returned to the
  // caller in non-production so the flow is still testable end to end.
  smtp: {
    host: process.env.SMTP_HOST?.trim() || '',
    port: int('SMTP_PORT', 587),
    secure: bool('SMTP_SECURE', false),
    user: process.env.SMTP_USER?.trim() || '',
    pass: process.env.SMTP_PASS ?? '',
    from: process.env.MAIL_FROM?.trim() || 'AURIX <no-reply@aurix.app>',
  },
  get mailEnabled() {
    return Boolean(this.smtp.host && this.smtp.user);
  },

  // Where password-reset links point. The app deep-links back in through
  // this, so it is configuration rather than a constant.
  publicAppUrl: process.env.PUBLIC_APP_URL?.trim() || '',

  // ---- Phone sign-in ----------------------------------------------------
  //
  // Every number here is a security parameter rather than a preference. A
  // six-digit code is one guess in a million, which is only strong while the
  // *number of guesses* is small and the window is short — so the TTL, the
  // attempt cap and the send cap are the control, not the digit count.
  otp: {
    length: int('OTP_LENGTH', 6),
    ttlMinutes: int('OTP_TTL_MINUTES', 5),
    /** Wrong guesses before the code is burned and a new one must be sent. */
    maxAttempts: int('OTP_MAX_ATTEMPTS', 5),
    /** Codes that may be sent to one number per hour, whatever the IP. */
    sendsPerHour: int('OTP_SENDS_PER_HOUR', 5),
    /** How long the app makes the user wait before "Resend" does anything. */
    resendSeconds: int('OTP_RESEND_SECONDS', 30),

    /**
     * Where a code goes when no SMS provider is configured.
     *
     * Empty — the default, and the only value production honours — means
     * **nowhere**: phone sign-in is switched off entirely rather than falling
     * back to something that pretends. A code the server cannot deliver is not
     * a degraded sign-in, it is an unauthenticated login for whoever can read
     * wherever it ended up.
     *
     * `file` writes it to [otpDevFile] instead, for developing against this
     * flow without an SMS account. It is refused in production, it is not a
     * response, not an error, and not a console line — the one place the code
     * can be read is a git-ignored file on the machine running the server.
     */
    devDelivery: isProduction ? '' : (process.env.OTP_DEV_DELIVERY ?? '').trim().toLowerCase(),
  },

  /** Where `OTP_DEV_DELIVERY=file` writes. Git-ignored; never served. */
  otpDevFile: process.env.OTP_DEV_FILE?.trim() || 'otp-dev.log',

  /**
   * Country code assumed for a number typed without one, e.g. `+44`.
   *
   * Empty means "insist on a country code", which is the safe default: there
   * is no library here that knows national numbering plans, and guessing at a
   * region would silently send someone else's phone a code. A deployment that
   * knows its audience sets this and lets people type the number the way they
   * say it out loud.
   */
  defaultPhoneCountryCode: (process.env.DEFAULT_PHONE_COUNTRY_CODE ?? '')
    .trim()
    .replace(/^00/, '+'),

  // Twilio, reached over plain HTTPS rather than through their SDK — one
  // POST with basic auth is not worth a dependency. Absent credentials are a
  // supported configuration for exactly the reason absent SMTP is: the flow
  // has to be exercisable on a laptop. See `services/sms.js`.
  sms: {
    accountSid: process.env.TWILIO_ACCOUNT_SID?.trim() || '',
    authToken: process.env.TWILIO_AUTH_TOKEN ?? '',
    from: process.env.TWILIO_FROM?.trim() || '',
    messagingServiceSid: process.env.TWILIO_MESSAGING_SERVICE_SID?.trim() || '',
  },
  get smsEnabled() {
    return Boolean(
      this.sms.accountSid &&
        this.sms.authToken &&
        (this.sms.from || this.sms.messagingServiceSid),
    );
  },

  /**
   * Whether a sign-in code can actually reach a handset.
   *
   * The gate on the whole phone method. False means the login screen is not
   * offered the option and `POST /auth/phone/start` refuses — which is the
   * correct behaviour, because the alternative is generating a credential and
   * dropping it on the floor.
   */
  get phoneSignInEnabled() {
    return this.smsEnabled || this.otp.devDelivery === 'file';
  },

  // ---- Social sign-in ---------------------------------------------------
  //
  // ## Every one of these secrets is a server secret
  //
  // The client id of an OAuth application is public; the client secret is
  // not, and there is no way to keep one inside a mobile binary. So the app
  // never sees any of this: it asks this server to start a flow, the browser
  // goes to the provider, the provider comes back *here*, and this process
  // does the code-for-token exchange with the secret it holds. What crosses
  // back to the app is a single-use AURIX grant, and never a provider token.
  //
  // That is also why [publicApiUrl] is required for social sign-in and for
  // nothing else: it is the address the *provider* redirects a browser to, so
  // it has to be reachable from the public internet and has to match the
  // callback URL registered in each provider's console exactly.

  /** This server's public origin — where providers send the browser back. */
  publicApiUrl: (process.env.PUBLIC_API_URL ?? '').trim().replace(/\/+$/, ''),

  /**
   * App redirect URIs this server will hand a grant to.
   *
   * An exact-match allow-list, and the reason it exists is worth stating: the
   * final hop of the flow puts a one-time credential in a URL. Without a list,
   * `?redirect_uri=https://attacker.example` would make this server post that
   * credential wherever it was asked to — an open redirector with a session
   * attached to it.
   */
  oauthAppRedirects: (process.env.OAUTH_APP_REDIRECTS ?? 'aurix://login-callback')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  /** How long a browser-flow transaction, and the grant it produces, live. */
  oauthStateMinutes: int('OAUTH_STATE_MINUTES', 10),
  oauthGrantMinutes: int('OAUTH_GRANT_MINUTES', 10),

  oauth: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID?.trim() || '',
      clientSecret: process.env.GOOGLE_CLIENT_SECRET ?? '',
    },
    // Apple has no client *secret*: it has a signing key, and the secret is a
    // short-lived ES256 JWT this server mints from it on every exchange. The
    // .p8 body is stored with literal \n escapes so it survives a one-line
    // environment variable; `services/oauth/providers.js` unescapes it.
    apple: {
      clientId: process.env.APPLE_SERVICES_ID?.trim() || '',
      teamId: process.env.APPLE_TEAM_ID?.trim() || '',
      keyId: process.env.APPLE_KEY_ID?.trim() || '',
      privateKey: (process.env.APPLE_PRIVATE_KEY ?? '').replace(/\\n/g, '\n').trim(),
    },
    facebook: {
      clientId: process.env.FACEBOOK_APP_ID?.trim() || '',
      clientSecret: process.env.FACEBOOK_APP_SECRET ?? '',
    },
    github: {
      clientId: process.env.GITHUB_CLIENT_ID?.trim() || '',
      clientSecret: process.env.GITHUB_CLIENT_SECRET ?? '',
    },
  },

};

/**
 * The sign-in methods this deployment can actually serve.
 *
 * Email and password is unconditional — it needs nothing but the database.
 * Everything else needs credentials, and a method whose credentials are absent
 * is reported to the app as unavailable rather than offered and then failing
 * in a browser tab.
 *
 * Phone is on the same footing as the four providers, and that is deliberate:
 * without a way to actually deliver an SMS there is no phone sign-in, only a
 * button that generates a credential and discards it.
 */
export function signInMethods() {
  const oauth = Object.entries(env.oauth)
    .filter(([id, cfg]) =>
      id === 'apple'
        ? Boolean(cfg.clientId && cfg.teamId && cfg.keyId && cfg.privateKey)
        : Boolean(cfg.clientId && cfg.clientSecret),
    )
    // A provider cannot come back to a server with no public address, so an
    // unset PUBLIC_API_URL disables all of them at once. Silently offering
    // them would send users to a consent screen that redirects nowhere.
    .filter(() => env.publicApiUrl.length > 0)
    .map(([id]) => id);

  return ['password', ...(env.phoneSignInEnabled ? ['phone'] : []), ...oauth];
}

/**
 * A one-line boot summary that is safe to log.
 *
 * Every secret is reduced to present/absent. This is deliberately the only
 * function in the codebase that formats configuration for output — logging
 * `env` directly anywhere would put the Mongo credentials in a log file.
 */
export function debugSummary() {
  const host = (() => {
    try {
      // Print the cluster host, never the credentials.
      return new URL(env.mongoUri.replace(/^mongodb\+srv:\/\//, 'https://')).host;
    } catch {
      return 'unparsed';
    }
  })();

  return [
    `env=${env.nodeEnv}`,
    `port=${env.port}`,
    `db=${env.dbName}@${host}`,
    `mail=${env.mailEnabled ? 'smtp' : 'console'}`,
    `cors=${env.corsOrigins.length > 0 ? env.corsOrigins.join('|') : 'reflect'}`,
    // Which ways in are actually usable on this deployment. Worth a word in
    // the boot line because a missing client secret does not fail at boot —
    // it fails when someone taps "Continue with Google", by which point the
    // question is "was that ever configured?".
    `signin=${signInMethods().join('|')}`,
  ].join(' ');
}
