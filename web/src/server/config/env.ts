/**
 * Runtime configuration for the AURIX API.
 *
 * Ported from `server/src/config/env.js`. Everything secret lives here and
 * nowhere else, and the one rule this module exists to enforce is unchanged:
 * **no secret is ever sent to a client.** The Mongo connection string, the JWT
 * signing keys and the SMTP password are read from the process environment,
 * used inside this process, and never appear in a response body — not in an
 * error, not in a health check, not in the portal's bootstrap payload.
 *
 * ## The one behavioural change, and why it had to change
 *
 * The Express version validated at *module load* and threw, which stopped the
 * process from starting. That was the right design for a long-lived server: a
 * process that starts without a database URI and then 500s on every call is
 * strictly worse than one that refuses to start and names the missing key.
 *
 * There is no boot on Vercel. A module-level throw here would instead fire
 * during `next build`, when the build machine legitimately has no production
 * secrets, and fail the build rather than catch a misconfiguration.
 *
 * So validation moved from load time to *first use*: [assertConfigured] is
 * called by the database connector and by the token signer, which is the
 * earliest moment on serverless that corresponds to "boot" on a server. The
 * property that was actually valuable — a missing key produces one clear
 * message naming it, rather than a confusing failure much later — is preserved.
 *
 * Nothing loads dotenv. Next.js reads `.env.local` (and `.env`) itself before
 * any application code runs, and on Vercel the values come from the project's
 * environment settings.
 */

function str(key: string, fallback = ''): string {
  const raw = process.env[key];
  return raw === undefined || raw.trim() === '' ? fallback : raw.trim();
}

/** Not trimmed: a password or signing key may legitimately begin or end with a space. */
function secret(key: string, fallback = ''): string {
  const raw = process.env[key];
  return raw === undefined || raw === '' ? fallback : raw;
}

function int(key: string, fallback: number): number {
  const parsed = Number.parseInt(process.env[key] ?? '', 10);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function bool(key: string, fallback: boolean): boolean {
  const raw = process.env[key];
  if (raw === undefined || raw.trim() === '') return fallback;
  return ['1', 'true', 'yes', 'on'].includes(raw.trim().toLowerCase());
}

function list(key: string, fallback = ''): string[] {
  return (process.env[key] ?? fallback)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

const nodeEnv = process.env.NODE_ENV ?? 'development';
const isProduction = nodeEnv === 'production';

const mongoUri = str('MONGODB_URI');
const jwtSecret = secret('JWT_SECRET');

/**
 * Falls back to a *derived* key rather than to the access-token key itself, so
 * a deployment that sets only JWT_SECRET still cannot have a refresh token
 * accepted where an access token is expected.
 */
const refreshSecret = secret('JWT_REFRESH_SECRET', jwtSecret ? `${jwtSecret}::refresh` : '');

export type ProviderId = 'google' | 'apple' | 'facebook' | 'github';

export const env = {
  nodeEnv,
  isProduction,

  // ---- Database ---------------------------------------------------------
  mongoUri,
  dbName: str('MONGODB_DB', 'aurix'),

  /**
   * DNS resolvers to use for the `mongodb+srv://` lookup, if the default one
   * cannot do it.
   *
   * A `mongodb+srv://` URI is not an address — it is an instruction to look up
   * a DNS **SRV** record and connect to whatever hosts it names. The driver
   * does that with `dns.resolveSrv`, which talks to a DNS server directly on
   * port 53 rather than going through the operating system's resolver.
   *
   * A surprising number of networks break that specific path while ordinary
   * browsing works perfectly: corporate DNS that answers A records and refuses
   * SRV, a VPN capturing port 53, a router whose resolver rejects anything
   * unusual. The symptom is `querySrv ECONNREFUSED`, which is reported by the
   * MongoDB driver and therefore reads like a database problem — it is not, and
   * it happens before a single byte reaches Atlas.
   *
   * ## Why this survived the port
   *
   * It was initially dropped as a Vercel-irrelevant workaround, which was true
   * of Vercel and wrong about everywhere else: the development machine this was
   * ported on is one of the networks that refuses SRV, and without this the
   * local API cannot reach Atlas at all. A deployment concern and a development
   * concern are not the same concern.
   *
   * Empty — the right value on Vercel — means "use whatever this machine is
   * configured with", and nothing is overridden.
   */
  dnsServers: list('DNS_SERVERS'),

  // ---- Tokens -----------------------------------------------------------
  jwtSecret,
  refreshSecret,
  accessTokenTtl: str('ACCESS_TOKEN_TTL', '30m'),
  refreshTokenDays: int('REFRESH_TOKEN_DAYS', 60),
  /** Password-reset and email-verification links. */
  actionTokenMinutes: int('ACTION_TOKEN_MINUTES', 60),

  // ---- CORS -------------------------------------------------------------
  // A comma-separated allow-list. Empty means "reflect the request origin",
  // which is right for local development and wrong for production.
  corsOrigins: list('CORS_ORIGINS'),

  // ---- Uploads ----------------------------------------------------------
  maxLogoBytes: int('MAX_LOGO_BYTES', 2 * 1024 * 1024),
  // 3.5MB, not the server's 4MB. Vercel rejects any request body over 4.5MB
  // before the function runs, so a legitimate 4MB font plus multipart overhead
  // could fail with a platform error instead of this API's `payload_too_large`.
  maxFontBytes: int('MAX_FONT_BYTES', 3.5 * 1024 * 1024),

  // ---- Admin bootstrap --------------------------------------------------
  bootstrapAdminEmail: str('BOOTSTRAP_ADMIN_EMAIL').toLowerCase(),

  // ---- Mail (optional) --------------------------------------------------
  smtp: {
    host: str('SMTP_HOST'),
    port: int('SMTP_PORT', 587),
    secure: bool('SMTP_SECURE', false),
    user: str('SMTP_USER'),
    pass: secret('SMTP_PASS'),
    from: str('MAIL_FROM', 'AURIX <no-reply@aurix.app>'),
  },
  get mailEnabled(): boolean {
    return Boolean(this.smtp.host && this.smtp.user);
  },

  publicAppUrl: str('PUBLIC_APP_URL'),

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
  },

  /**
   * Country code assumed for a number typed without one, e.g. `+44`.
   *
   * Empty means "insist on a country code", which is the safe default: there
   * is no library here that knows national numbering plans, and guessing at a
   * region would silently send someone else's phone a code that signs in as
   * them.
   */
  defaultPhoneCountryCode: str('DEFAULT_PHONE_COUNTRY_CODE').replace(/^00/, '+'),

  // Twilio, reached over plain HTTPS rather than through their SDK — one POST
  // with basic auth is not worth a dependency.
  sms: {
    accountSid: str('TWILIO_ACCOUNT_SID'),
    authToken: secret('TWILIO_AUTH_TOKEN'),
    from: str('TWILIO_FROM'),
    messagingServiceSid: str('TWILIO_MESSAGING_SERVICE_SID'),
  },
  get smsEnabled(): boolean {
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
   * offered the option and `POST /auth/phone/start` refuses — which is correct,
   * because the alternative is generating a credential and dropping it on the
   * floor.
   *
   * Note what is *missing* compared with the Express version: there is no
   * `OTP_DEV_DELIVERY=file` escape hatch. It wrote plaintext one-time codes to
   * a file on disk, which serverless has no durable version of, and it was a
   * local development affordance that should not outlive the migration. Phone
   * sign-in now requires a real SMS provider, in every environment.
   */
  get phoneSignInEnabled(): boolean {
    return this.smsEnabled;
  },

  // ---- Social sign-in ---------------------------------------------------
  //
  // ## Every one of these secrets is a server secret
  //
  // The client id of an OAuth application is public; the client secret is not,
  // and there is no way to keep one inside a mobile binary. So the app never
  // sees any of this: it asks this deployment to start a flow, the browser goes
  // to the provider, the provider comes back *here*, and this code does the
  // code-for-token exchange with the secret it holds. What crosses back to the
  // app is a single-use AURIX grant, and never a provider token.

  /** This deployment's public origin — where providers send the browser back. */
  publicApiUrl: str('PUBLIC_API_URL').replace(/\/+$/, ''),

  /**
   * App redirect URIs this deployment will hand a grant to.
   *
   * An exact-match allow-list, and the reason it exists is worth stating: the
   * final hop of the flow puts a one-time credential in a URL. Without a list,
   * `?redirect_uri=https://attacker.example` would make this API post that
   * credential wherever it was asked to — an open redirector with a session
   * attached to it.
   */
  oauthAppRedirects: list('OAUTH_APP_REDIRECTS', 'aurix://login-callback'),

  oauthStateMinutes: int('OAUTH_STATE_MINUTES', 10),
  oauthGrantMinutes: int('OAUTH_GRANT_MINUTES', 10),

  oauth: {
    google: {
      clientId: str('GOOGLE_CLIENT_ID'),
      clientSecret: secret('GOOGLE_CLIENT_SECRET'),
    },
    // Apple has no client *secret*: it has a signing key, and the secret is a
    // short-lived ES256 JWT minted from it on every exchange. The .p8 body is
    // stored with literal \n escapes so it survives a one-line environment
    // variable; it is unescaped here.
    apple: {
      clientId: str('APPLE_SERVICES_ID'),
      teamId: str('APPLE_TEAM_ID'),
      keyId: str('APPLE_KEY_ID'),
      privateKey: secret('APPLE_PRIVATE_KEY').replace(/\\n/g, '\n').trim(),
    },
    facebook: {
      clientId: str('FACEBOOK_APP_ID'),
      clientSecret: secret('FACEBOOK_APP_SECRET'),
    },
    github: {
      clientId: str('GITHUB_CLIENT_ID'),
      clientSecret: secret('GITHUB_CLIENT_SECRET'),
    },
  },
} as const;

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/** Required keys that are absent or blank. Empty means the API can serve. */
export function missingRequired(): string[] {
  const missing: string[] = [];
  if (!env.mongoUri) missing.push('MONGODB_URI');
  if (!env.jwtSecret) missing.push('JWT_SECRET');
  if (!env.refreshSecret) missing.push('JWT_REFRESH_SECRET');
  return missing;
}

/**
 * Throws unless the API is configured well enough to serve a request.
 *
 * Called by the database connector and the token signer rather than at module
 * load — see the note at the top of this file for why. The message names the
 * missing keys, because the failure it is most likely to describe is a
 * deployment where someone forgot to copy one across.
 */
export function assertConfigured(): void {
  const missing = missingRequired();
  if (missing.length === 0) return;
  throw new Error(
    `AURIX API is not configured: missing ${missing.length > 1 ? 'variables' : 'variable'} ` +
      `${missing.join(', ')}. Set ${missing.length > 1 ? 'them' : 'it'} in web/.env.local ` +
      'for local development, or in the Vercel project environment for a deployment. ' +
      'See web/.env.example.',
  );
}

/**
 * The sign-in methods this deployment can actually serve.
 *
 * Email and password is unconditional — it needs nothing but the database.
 * Everything else needs credentials, and a method whose credentials are absent
 * is reported to the app as unavailable rather than offered and then failing in
 * a browser tab.
 */
export function signInMethods(): string[] {
  const oauth = (Object.keys(env.oauth) as ProviderId[]).filter((id) => {
    const cfg = env.oauth[id];
    const configured =
      id === 'apple'
        ? Boolean(cfg.clientId && 'teamId' in cfg && cfg.teamId && cfg.keyId && cfg.privateKey)
        : Boolean(cfg.clientId && 'clientSecret' in cfg && cfg.clientSecret);
    // A provider cannot come back to a deployment with no public address, so an
    // unset PUBLIC_API_URL disables all of them at once. Silently offering them
    // would send users to a consent screen that redirects nowhere.
    return configured && env.publicApiUrl.length > 0;
  });

  return ['password', ...(env.phoneSignInEnabled ? ['phone'] : []), ...oauth];
}

/**
 * A one-line summary that is safe to log.
 *
 * Every secret is reduced to present/absent. This is deliberately the only
 * function that formats configuration for output — logging `env` directly
 * anywhere would put the Mongo credentials in a log file.
 */
export function debugSummary(): string {
  // The cluster host, never the credentials.
  //
  // Parsed by hand rather than with `new URL`, which the Express version used
  // and which only worked for the `mongodb+srv://` form: a non-SRV Atlas URI
  // lists several comma-separated hosts, and `new URL` rejects it — printing
  // `unparsed` exactly where the summary is meant to say which cluster this is.
  const host = (() => {
    const withoutScheme = env.mongoUri.replace(/^mongodb(\+srv)?:\/\//, '');
    const afterCredentials = withoutScheme.slice(withoutScheme.lastIndexOf('@') + 1);
    const hosts = afterCredentials.split(/[/?]/)[0] ?? '';
    if (!hosts) return 'unparsed';
    const [first = '', ...rest] = hosts.split(',');
    // "host:27017 (+2)" rather than three near-identical shard names.
    return rest.length > 0 ? `${first} (+${rest.length})` : first;
  })();

  return [
    `env=${env.nodeEnv}`,
    `db=${env.dbName}@${host}`,
    `mail=${env.mailEnabled ? 'smtp' : 'console'}`,
    `cors=${env.corsOrigins.length > 0 ? env.corsOrigins.join('|') : 'reflect'}`,
    `signin=${signInMethods().join('|')}`,
  ].join(' ');
}
