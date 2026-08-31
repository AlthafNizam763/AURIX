import crypto from 'node:crypto';

import jwt from 'jsonwebtoken';

import { env } from '../../config/env';
import type { ProviderId, SocialProfile } from '../../db/documents';
import { ApiError, badRequest, providerUnavailable, unavailable } from '../../utils/errors';

/**
 * The four social providers, each reduced to the same four questions.
 *
 * ```
 * isConfigured()                     — are this deployment's credentials set?
 * authorizeUrl({ state, nonce, … })  — where to send the browser
 * exchange({ code, verifier })       — code -> provider tokens (SECRET USED HERE)
 * profile(tokens, extra)             — provider tokens -> { subject, email, … }
 * ```
 *
 * Everything above that — the state table, the one-time grant, deciding whether
 * a profile is a new account or a link — lives in `flow.ts` and is written once.
 * Adding a fifth provider is an entry in [PROVIDERS] and nothing else.
 *
 * ## Where the secrets are, and why that is the whole point
 *
 * `exchange` is the only function in AURIX that touches a client secret, and it
 * runs on the server. The app never sees one, cannot see one, and does not need
 * one: it asks this deployment to start a flow and redeems an AURIX grant at the
 * end of it. A client secret compiled into an APK is a client secret published
 * to everyone who installs it, and no amount of obfuscation changes that — the
 * same reasoning that keeps `MONGODB_URI` out of the Flutter half.
 *
 * ## Why the id_token signatures are not verified against JWKS
 *
 * Google and Apple both return an `id_token`, and the usual advice is to verify
 * its signature against the provider's published keys. That advice is for tokens
 * received from *somewhere else* — a client, a redirect, a header. These are
 * read out of the body of a TLS response to a request this server made directly
 * to `oauth2.googleapis.com` / `appleid.apple.com`, which is exactly the case
 * both providers document as not requiring verification: the channel already
 * authenticates the issuer.
 *
 * The claims are still checked, because TLS says who sent the token and not
 * what is in it: `iss`, `aud` and `exp` are asserted, and `nonce` is matched
 * against the value this server generated for this transaction.
 */

/** A provider failure carries the provider's own diagnosis, for the log only. */
export interface ProviderError extends ApiError {
  providerDetail?: string;
}

export interface AuthorizeParams {
  state: string;
  nonce: string;
  redirectUri: string;
  codeChallenge: string;
}

export interface ExchangeParams {
  code: string;
  redirectUri: string;
  verifier: string;
}

/** Provider token responses vary; only the fields actually read are named. */
export interface ProviderTokens {
  access_token?: string;
  id_token?: string;
  [key: string]: unknown;
}

export interface ProfileExtras {
  nonce?: string;
  /** Apple's form-POST callback body. The only place its `user` field appears. */
  formBody?: Record<string, string> | null;
}

export interface Provider {
  id: ProviderId;
  label: string;
  usesPkce: boolean;
  usesNonce: boolean;
  responseMode?: 'form_post';
  isConfigured(): boolean;
  authorizeUrl(params: AuthorizeParams): string;
  exchange(params: ExchangeParams): Promise<ProviderTokens>;
  profile(tokens: ProviderTokens, extras: ProfileExtras): Promise<SocialProfile>;
}

/** Reads a JWT payload without verifying the signature. See the note above. */
function claimsOf(token: unknown): Record<string, unknown> {
  const parts = String(token ?? '').split('.');
  if (parts.length !== 3) throw badRequest('The provider returned a malformed token.');
  try {
    return JSON.parse(Buffer.from(parts[1] ?? '', 'base64url').toString('utf8'));
  } catch {
    throw badRequest('The provider returned a malformed token.');
  }
}

/**
 * Asserts the claims that TLS cannot: who the token is *for*, and whether it
 * belongs to the transaction that is in flight.
 */
function assertClaims(
  claims: Record<string, unknown>,
  { issuers, audience, nonce }: { issuers: string[]; audience: string; nonce?: string },
): void {
  const issuer = String(claims.iss ?? '');
  if (!issuers.includes(issuer)) {
    throw badRequest('That sign-in came back from an unexpected issuer.');
  }
  // `aud` is an array in the OIDC spec and a string in practice.
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  if (!audiences.includes(audience)) {
    throw badRequest('That sign-in was issued for a different application.');
  }
  if (typeof claims.exp === 'number' && claims.exp * 1000 < Date.now()) {
    throw badRequest('That sign-in took too long. Try again.');
  }
  // The replay defence. A token captured from an earlier flow carries an
  // earlier nonce and is refused here even though everything else about it is
  // valid.
  if (nonce && claims.nonce !== nonce) {
    throw badRequest('That sign-in could not be matched to this device. Try again.');
  }
}

const TIMEOUT_MS = 15_000;

/** Calls a provider endpoint and insists on JSON. */
async function callProvider(
  provider: string,
  url: string,
  {
    method = 'GET',
    headers = {},
    body,
  }: { method?: string; headers?: Record<string, string>; body?: string } = {},
): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await fetch(url, {
      method,
      headers: { Accept: 'application/json', ...headers },
      body,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch {
    throw unavailable(`Could not reach ${provider}. Try again in a moment.`);
  }

  const text = await response.text();
  let parsed: Record<string, unknown>;
  try {
    parsed = text.length > 0 ? JSON.parse(text) : {};
  } catch {
    parsed = {};
  }

  if (!response.ok || parsed.error) {
    // The provider's own diagnosis goes to the log and nowhere near the user:
    // it routinely names the client id and the exact misconfiguration, which is
    // precisely what makes it useful to an operator and inappropriate in a
    // response body.
    const err = parsed.error as { message?: string } | string | undefined;
    const detail =
      parsed.error_description ??
      (typeof err === 'object' ? err?.message : err) ??
      text.slice(0, 300);
    const failure = unavailable(`${provider} refused that sign-in. Try again.`) as ProviderError;
    failure.providerDetail = String(detail);
    throw failure;
  }

  return parsed;
}

const form = (fields: Record<string, string>): string =>
  new URLSearchParams(fields).toString();

const FORM_HEADERS = { 'Content-Type': 'application/x-www-form-urlencoded' };

const str = (value: unknown): string => (typeof value === 'string' ? value : '');

// ---------------------------------------------------------------------------
// Google
// ---------------------------------------------------------------------------

const google: Provider = {
  id: 'google',
  label: 'Google',
  /** PKCE on top of a confidential exchange. Free, and Google supports it. */
  usesPkce: true,
  usesNonce: true,

  isConfigured: () => Boolean(env.oauth.google.clientId && env.oauth.google.clientSecret),

  authorizeUrl({ state, nonce, redirectUri, codeChallenge }) {
    const params = new URLSearchParams({
      client_id: env.oauth.google.clientId,
      redirect_uri: redirectUri,
      response_type: 'code',
      scope: 'openid email profile',
      state,
      nonce,
      // No refresh token is wanted. AURIX reads the profile once, at sign-in,
      // and never acts on the user's behalf at Google again — asking for
      // offline access would be requesting a capability with no use for it.
      access_type: 'online',
      // Always show the chooser. Without it a shared device signs the second
      // person in as the first, silently, because Google reuses its session.
      prompt: 'select_account',
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });
    return `https://accounts.google.com/o/oauth2/v2/auth?${params}`;
  },

  exchange({ code, redirectUri, verifier }) {
    return callProvider('Google', 'https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: FORM_HEADERS,
      body: form({
        code,
        client_id: env.oauth.google.clientId,
        client_secret: env.oauth.google.clientSecret,
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
        code_verifier: verifier,
      }),
    });
  },

  async profile(tokens, { nonce }) {
    const claims = claimsOf(tokens.id_token);
    assertClaims(claims, {
      issuers: ['accounts.google.com', 'https://accounts.google.com'],
      audience: env.oauth.google.clientId,
      nonce,
    });

    return {
      subject: String(claims.sub),
      email: str(claims.email),
      // Google sets this false for Workspace addresses it has not confirmed.
      // Believing it blindly is how an unverified address becomes an account
      // takeover, so it is carried through exactly as given.
      emailVerified: claims.email_verified === true || claims.email_verified === 'true',
      name: str(claims.name),
      avatarUrl: str(claims.picture),
    };
  },
};

// ---------------------------------------------------------------------------
// Apple
// ---------------------------------------------------------------------------

const apple: Provider = {
  id: 'apple',
  label: 'Apple',
  usesPkce: false,
  usesNonce: true,
  /**
   * Apple POSTs the callback instead of redirecting to it.
   *
   * Requesting the `name` or `email` scope forces `response_mode=form_post` —
   * Apple refuses the request otherwise. The callback route therefore accepts
   * both verbs, and this flag is what tells the flow to expect it.
   */
  responseMode: 'form_post',

  isConfigured: () =>
    Boolean(
      env.oauth.apple.clientId &&
        env.oauth.apple.teamId &&
        env.oauth.apple.keyId &&
        env.oauth.apple.privateKey,
    ),

  authorizeUrl({ state, nonce, redirectUri }) {
    const params = new URLSearchParams({
      client_id: env.oauth.apple.clientId,
      redirect_uri: redirectUri,
      response_type: 'code',
      scope: 'name email',
      response_mode: 'form_post',
      state,
      nonce,
    });
    return `https://appleid.apple.com/auth/authorize?${params}`;
  },

  exchange({ code, redirectUri }) {
    return callProvider('Apple', 'https://appleid.apple.com/auth/token', {
      method: 'POST',
      headers: FORM_HEADERS,
      body: form({
        code,
        client_id: env.oauth.apple.clientId,
        // Apple has no static secret. This is a fresh ES256 assertion, signed
        // with the .p8 key, valid for a few minutes and good for one exchange.
        client_secret: appleClientSecret(),
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
  },

  async profile(tokens, { nonce, formBody }) {
    const claims = claimsOf(tokens.id_token);
    assertClaims(claims, {
      issuers: ['https://appleid.apple.com'],
      audience: env.oauth.apple.clientId,
      nonce,
    });

    const email = str(claims.email);

    return {
      subject: String(claims.sub),
      email,
      // Apple states verification as the string 'true' about as often as the
      // boolean. An address Apple issued — including a relay one — is one it
      // controls delivery to, so it is verified by construction.
      emailVerified:
        claims.email_verified === true ||
        claims.email_verified === 'true' ||
        isApplePrivateRelay(email),
      isPrivateRelay:
        claims.is_private_email === true ||
        claims.is_private_email === 'true' ||
        isApplePrivateRelay(email),
      // **Only ever present on the very first authorization.** Apple sends the
      // name once, in a form field beside the code, and never again — not in
      // the id_token, not from any endpoint. An account created without
      // capturing it here can never learn it from Apple, which is why this is
      // read from the raw callback body rather than from the token.
      name: appleNameFrom(formBody),
      avatarUrl: '',
    };
  },
};

/** True for the per-app forwarding addresses Apple mints. */
export function isApplePrivateRelay(email: unknown): boolean {
  return (
    typeof email === 'string' && email.toLowerCase().endsWith('@privaterelay.appleid.com')
  );
}

/** Apple's one-shot `user` field: `{"name":{"firstName":…,"lastName":…}}`. */
function appleNameFrom(formBody: Record<string, string> | null | undefined): string {
  const raw = formBody?.user;
  if (typeof raw !== 'string' || raw.length === 0) return '';
  try {
    const parsed = JSON.parse(raw) as { name?: { firstName?: string; lastName?: string } };
    const first = parsed?.name?.firstName ?? '';
    const last = parsed?.name?.lastName ?? '';
    return `${first} ${last}`.trim();
  } catch {
    return '';
  }
}

/**
 * Apple's client secret: an ES256 JWT this server signs on every exchange.
 *
 * Short-lived on purpose. Apple permits up to six months, and a six-month
 * assertion cached somewhere is a six-month credential; minting one per
 * exchange means there is never a copy to leak.
 */
function appleClientSecret(): string {
  const { clientId, teamId, keyId, privateKey } = env.oauth.apple;
  const now = Math.floor(Date.now() / 1000);
  try {
    return jwt.sign(
      {
        iss: teamId,
        iat: now,
        exp: now + 5 * 60,
        aud: 'https://appleid.apple.com',
        sub: clientId,
      },
      privateKey,
      { algorithm: 'ES256', keyid: keyId },
    );
  } catch (error) {
    // Almost always a mangled APPLE_PRIVATE_KEY — the .p8 body pasted into a
    // one-line environment variable with its newlines lost. Named explicitly,
    // because "Apple refused that sign-in" sends an operator looking in the
    // wrong console.
    const failure = providerUnavailable('Apple') as ProviderError;
    failure.providerDetail =
      `Could not sign Apple's client secret (${(error as Error).message}). Check that ` +
      'APPLE_PRIVATE_KEY holds the whole .p8 body with its newlines escaped.';
    throw failure;
  }
}

// ---------------------------------------------------------------------------
// Facebook
// ---------------------------------------------------------------------------

const FACEBOOK_API = 'https://graph.facebook.com/v21.0';

const facebook: Provider = {
  id: 'facebook',
  label: 'Facebook',
  usesPkce: true,
  usesNonce: false,

  isConfigured: () =>
    Boolean(env.oauth.facebook.clientId && env.oauth.facebook.clientSecret),

  authorizeUrl({ state, redirectUri, codeChallenge }) {
    const params = new URLSearchParams({
      client_id: env.oauth.facebook.clientId,
      redirect_uri: redirectUri,
      state,
      response_type: 'code',
      scope: 'email,public_profile',
      code_challenge: codeChallenge,
      code_challenge_method: 'S256',
    });
    return `https://www.facebook.com/v21.0/dialog/oauth?${params}`;
  },

  exchange({ code, redirectUri, verifier }) {
    const params = new URLSearchParams({
      client_id: env.oauth.facebook.clientId,
      client_secret: env.oauth.facebook.clientSecret,
      redirect_uri: redirectUri,
      code,
      code_verifier: verifier,
    });
    return callProvider('Facebook', `${FACEBOOK_API}/oauth/access_token?${params}`);
  },

  async profile(tokens) {
    const token = String(tokens.access_token ?? '');
    const params = new URLSearchParams({
      fields: 'id,name,email,picture.type(large)',
      access_token: token,
      // Signs the call with the app secret so a token stolen from elsewhere
      // cannot be replayed against this application's Graph quota. Facebook
      // recommends it for every server-side call and it costs one HMAC.
      appsecret_proof: crypto
        .createHmac('sha256', env.oauth.facebook.clientSecret)
        .update(token)
        .digest('hex'),
    });
    const me = await callProvider('Facebook', `${FACEBOOK_API}/me?${params}`);

    const email = str(me.email);
    return {
      subject: String(me.id),
      email,
      // Facebook only ever discloses a confirmed address, and omits the field
      // entirely for accounts registered against a phone number. So "present"
      // is the same statement as "verified" here — and an absent email means
      // this sign-in creates its own account, because there is nothing to match
      // an existing one on.
      emailVerified: email.length > 0,
      name: str(me.name),
      avatarUrl: (me.picture as { data?: { url?: string } })?.data?.url ?? '',
    };
  },
};

// ---------------------------------------------------------------------------
// GitHub
// ---------------------------------------------------------------------------

interface GitHubEmail {
  email?: string;
  primary?: boolean;
  verified?: boolean;
}

const github: Provider = {
  id: 'github',
  label: 'GitHub',
  // GitHub's OAuth apps — as opposed to GitHub Apps — do not implement PKCE,
  // and sending the parameters is not harmless: the exchange fails.
  usesPkce: false,
  usesNonce: false,

  isConfigured: () => Boolean(env.oauth.github.clientId && env.oauth.github.clientSecret),

  authorizeUrl({ state, redirectUri }) {
    const params = new URLSearchParams({
      client_id: env.oauth.github.clientId,
      redirect_uri: redirectUri,
      state,
      // `user:email` rather than `user`: the addresses are needed to link an
      // account, the rest of the profile is not, and an OAuth screen that asks
      // for less is one more people finish.
      scope: 'read:user user:email',
      allow_signup: 'true',
    });
    return `https://github.com/login/oauth/authorize?${params}`;
  },

  exchange({ code, redirectUri }) {
    return callProvider('GitHub', 'https://github.com/login/oauth/access_token', {
      method: 'POST',
      headers: FORM_HEADERS,
      body: form({
        client_id: env.oauth.github.clientId,
        client_secret: env.oauth.github.clientSecret,
        redirect_uri: redirectUri,
        code,
      }),
    });
  },

  async profile(tokens) {
    const headers = {
      Authorization: `Bearer ${String(tokens.access_token ?? '')}`,
      // GitHub rejects an API call with no User-Agent outright.
      'User-Agent': 'AURIX',
      'X-GitHub-Api-Version': '2022-11-28',
    };

    const me = await callProvider('GitHub', 'https://api.github.com/user', { headers });

    // `user.email` is the *public* profile address, which most accounts leave
    // empty, and it carries no verification claim. The addresses that can be
    // trusted come from the dedicated endpoint, which says which one is primary
    // and which are confirmed. An unverified address must never be used to
    // match an existing AURIX account: anyone can type anyone's address into
    // their GitHub settings.
    let email = '';
    let emailVerified = false;
    try {
      const addresses = (await callProvider('GitHub', 'https://api.github.com/user/emails', {
        headers,
      })) as unknown as GitHubEmail[];

      if (Array.isArray(addresses)) {
        const primary = addresses.find((a) => a?.primary && a?.verified);
        const chosen = primary ?? addresses.find((a) => a?.verified);
        if (chosen?.email) {
          email = String(chosen.email);
          emailVerified = true;
        }
      }
    } catch {
      // The scope can be declined. An account is still created, just without an
      // address to link on — which is the honest outcome, not a failure.
    }

    return {
      subject: String(me.id),
      email,
      emailVerified,
      name: str(me.name) || str(me.login),
      avatarUrl: str(me.avatar_url),
    };
  },
};

// ---------------------------------------------------------------------------

export const PROVIDERS: Record<ProviderId, Provider> = { google, apple, facebook, github };

export const PROVIDER_IDS = Object.keys(PROVIDERS) as ProviderId[];

export function isProviderId(value: unknown): value is ProviderId {
  return typeof value === 'string' && (PROVIDER_IDS as string[]).includes(value);
}

/** The provider, or a 503 naming it — never `undefined` reaching a handler. */
export function requireProvider(id: string): Provider {
  const provider = isProviderId(id) ? PROVIDERS[id] : undefined;
  if (!provider) throw badRequest('That sign-in method does not exist.');
  if (!provider.isConfigured() || env.publicApiUrl.length === 0) {
    throw providerUnavailable(provider.label);
  }
  return provider;
}

/** Those a deployment has credentials for. Mirrors `signInMethods` in env. */
export function configuredProviders(): ProviderId[] {
  if (env.publicApiUrl.length === 0) return [];
  return PROVIDER_IDS.filter((id) => PROVIDERS[id].isConfigured());
}

/** The name to put in front of a user, e.g. `github` -> `GitHub`. */
export function providerLabel(id: string): string {
  return isProviderId(id) ? PROVIDERS[id].label : id;
}
