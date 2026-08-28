import crypto from 'node:crypto';

import { env } from '../../config/env.js';
import { collections } from '../../db/mongo.js';
import { badRequest, invalidAuthState, unauthorized } from '../../utils/errors.js';
import { log } from '../../utils/logger.js';
import { requireProvider } from './providers.js';

/**
 * The browser round trip, written once for every provider.
 *
 * ## The shape of the flow, and why it has this many hops
 *
 * ```
 *  app -- POST /auth/oauth/google/start ---------------> this server
 *      <-- { authorizationUrl } ------------------------
 *
 *  app -- opens the URL in a system browser -----------> Google
 *                            (user consents)
 *      <-- 302 to  {PUBLIC_API_URL}/../callback -------  this server
 *                    code -> tokens, using the CLIENT SECRET
 *                    tokens -> profile
 *                    profile -> AURIX account
 *      --- 302 to  aurix://login-callback?code=.. -----> app
 *
 *  app -- POST /auth/oauth/exchange { code } ----------> this server
 *      <-- a session, or a link challenge -------------
 * ```
 *
 * The obvious shorter design — let the app do the OAuth flow itself and post
 * the provider's token here — is the one that cannot be secured. It needs the
 * client secret inside the binary for every provider that requires one, and it
 * makes this server's trust in the app's word the only thing standing between
 * an attacker and any account: "here is an id_token, sign me in" is a request
 * anyone can make with a token obtained for a different application.
 *
 * Here, the provider's token never leaves this process, and the only thing the
 * app ever holds is a single-use AURIX grant that this server minted.
 *
 * ## The two tables
 *
 * **`authStates`** is a transaction in flight: the `state` the provider will
 * echo back, the PKCE verifier, the nonce, and — critically — the app redirect
 * this flow is allowed to return to. It is deleted the moment the callback is
 * handled, which is what makes a replayed callback fail.
 *
 * **`authGrants`** is what the app redeems. A `session` grant is consumed on
 * first use. A `link` grant survives being read, because the account-link
 * challenge is a conversation — send a code, then confirm it — and is deleted
 * when the link completes or when its TTL runs out.
 *
 * Both hold only a SHA-256 of the value the holder presents, for the same
 * reason `refreshTokens` does: a leaked backup must not contain live
 * credentials.
 */

const sha256 = (value) => crypto.createHash('sha256').update(value).digest('hex');

const opaque = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');

/** PKCE S256, per RFC 7636. Mirrors `Pkce` on the Dart side. */
function pkcePair() {
  const verifier = opaque(48);
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

/** Where the provider sends the browser back. Must match its console entry. */
export function callbackUrlFor(providerId) {
  return `${env.publicApiUrl}/api/v1/auth/oauth/${providerId}/callback`;
}

/**
 * The app redirect this flow may finish at.
 *
 * An exact-match allow-list, and the check is not a formality: the final hop
 * puts a one-time credential in a URL. Without it, `redirect_uri=https://..`
 * would make this server hand that credential to whoever asked — an open
 * redirector with a session attached.
 */
function assertAllowedRedirect(redirectUri) {
  const value = String(redirectUri ?? '').trim();
  if (!env.oauthAppRedirects.includes(value)) {
    throw badRequest(
      'That redirect address is not registered for this AURIX server. ' +
        'Add it to OAUTH_APP_REDIRECTS.',
    );
  }
  return value;
}

/**
 * Opens a transaction and returns the URL to put in front of the user.
 *
 * [intent] is `'signIn'` for the login screen and `'link'` when a signed-in
 * user is adding a method from Settings — in which case [actorUid] is baked
 * into the state, so the account being linked to is decided here and cannot be
 * influenced by anything that comes back from the browser.
 */
export async function beginFlow({ providerId, redirectUri, intent = 'signIn', actorUid, device }) {
  const provider = requireProvider(providerId);
  const appRedirect = assertAllowedRedirect(redirectUri);

  if (intent === 'link' && !actorUid) throw unauthorized();

  const state = opaque(24);
  const nonce = provider.usesNonce ? opaque(16) : '';
  const { verifier, challenge } = provider.usesPkce ? pkcePair() : { verifier: '', challenge: '' };
  const now = Date.now();

  await collections.authStates().insertOne({
    state,
    provider: providerId,
    intent,
    uid: intent === 'link' ? actorUid : null,
    redirectUri: appRedirect,
    verifier,
    nonce,
    device: device ?? null,
    createdAt: new Date(now),
    expiresAt: new Date(now + env.oauthStateMinutes * 60 * 1000),
  });

  const authorizationUrl = provider.authorizeUrl({
    state,
    nonce,
    redirectUri: callbackUrlFor(providerId),
    codeChallenge: challenge,
  });

  return { authorizationUrl, state, expiresInSeconds: env.oauthStateMinutes * 60 };
}

/** Consumes the state. A second callback with the same one finds nothing. */
export async function takeState(state) {
  if (typeof state !== 'string' || state.length === 0) throw invalidAuthState();
  const record = await collections.authStates().findOneAndDelete({ state });
  if (!record) throw invalidAuthState();
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    throw invalidAuthState();
  }
  return record;
}

/**
 * Mints the code the app redeems.
 *
 * Ten minutes, single use for a session and read-many for a pending link. The
 * plaintext is returned once, put in the redirect, and never stored.
 */
export async function issueGrant({ kind, provider, uid, payload = {} }) {
  const code = opaque(32);
  const now = Date.now();

  await collections.authGrants().insertOne({
    codeHash: sha256(code),
    kind,
    provider,
    uid: uid ?? null,
    payload,
    attempts: 0,
    createdAt: new Date(now),
    expiresAt: new Date(now + env.oauthGrantMinutes * 60 * 1000),
  });

  return code;
}

/** Reads a grant without spending it. Used by the link conversation. */
export async function peekGrant(code, kind) {
  if (typeof code !== 'string' || code.length === 0) throw invalidAuthState();
  const record = await collections.authGrants().findOne({ codeHash: sha256(code) });
  if (!record || (kind && record.kind !== kind)) throw invalidAuthState();
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    await collections.authGrants().deleteOne({ _id: record._id });
    throw invalidAuthState();
  }
  return record;
}

/** Reads and spends a grant. The delete is the check — see `rotateRefreshToken`. */
export async function takeGrant(code, kind) {
  if (typeof code !== 'string' || code.length === 0) throw invalidAuthState();
  // The delete *is* the check. Two devices redeeming the same grant both find
  // it with a read; only one can be the caller `findOneAndDelete` returns a
  // document to. Filtering on `kind` in the same operation keeps a link grant
  // from being spent as though it were a session.
  const filter = { codeHash: sha256(code), ...(kind ? { kind } : {}) };
  const record = await collections.authGrants().findOneAndDelete(filter);
  if (!record) throw invalidAuthState();
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    throw invalidAuthState();
  }
  return record;
}

export async function discardGrant(code) {
  if (typeof code !== 'string' || code.length === 0) return;
  await collections.authGrants().deleteOne({ codeHash: sha256(code) });
}

/**
 * Counts a failed proof against a link grant, burning it after [max].
 *
 * The link challenge accepts a password or a mailed code, so without a counter
 * a `link` grant would be an unmetered password oracle for the account it
 * names. Returns false once the grant has been destroyed.
 */
export async function countGrantAttempt(record, max = 5) {
  const attempts = (record.attempts ?? 0) + 1;
  if (attempts >= max) {
    await collections.authGrants().deleteOne({ _id: record._id });
    return false;
  }
  await collections.authGrants().updateOne({ _id: record._id }, { $set: { attempts } });
  return true;
}

/** Appends parameters to an app redirect, custom scheme or http alike. */
export function redirectWith(redirectUri, params) {
  const query = new URLSearchParams(params).toString();
  return `${redirectUri}${redirectUri.includes('?') ? '&' : '?'}${query}`;
}

const ESCAPES = { '<': '&lt;', '>': '&gt;', '&': '&amp;' };

/**
 * The page shown when there is nowhere safe to redirect to.
 *
 * Reached only when the callback carries no usable state — a stale tab, a
 * forged link, or a flow whose ten minutes ran out while the consent screen
 * was open. Redirecting anywhere here would mean trusting a parameter that has
 * just failed verification, so the browser stops with an explanation instead.
 */
export function deadEndPage(message) {
  const safe = String(message).replace(/[<>&]/g, (c) => ESCAPES[c]);
  return [
    '<!doctype html><meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width,initial-scale=1">',
    '<title>AURIX</title>',
    '<style>body{margin:0;display:grid;place-items:center;min-height:100vh;',
    'background:#0b0b0f;color:#e8e8ee;font:16px/1.6 system-ui,-apple-system,',
    'Segoe UI,Roboto,sans-serif;text-align:center;padding:24px}',
    'h1{font-size:20px;font-weight:600}p{max-width:34ch;color:#9a9aa8}</style>',
    '<div><h1>Sign-in did not complete</h1>',
    `<p>${safe}</p>`,
    '<p>Close this window and try again in AURIX.</p></div>',
  ].join('');
}

/** One place that decides how much of a provider failure reaches the log. */
export function logProviderFailure(providerId, error) {
  // `providerDetail` is the provider's own diagnosis. It routinely names the
  // client id and the exact misconfiguration, which makes it invaluable in a
  // log and unacceptable in a response body.
  const detail = error?.providerDetail ? ` - ${error.providerDetail}` : '';
  log.error(`${providerId} sign-in failed: ${error?.message ?? error}${detail}`, 'auth');
}
