import crypto from 'node:crypto';

import { env, musicProviders, type MusicProviderId } from '../../config/env';
import { collections } from '../../db/mongo';
import type { MusicAuthStateDoc, MusicConnectionDoc } from '../../db/documents';
import {
  badRequest,
  invalidAuthState,
  providerAuthRequired,
  providerReconnectRequired,
} from '../../utils/errors';
import { log } from '../../utils/logger';
import { open, seal } from './crypto';
import {
  musicProvider,
  OAuthError,
  requireMusicProvider,
  type TokenSet,
} from './providers';
import type { ProviderCredential } from './types';

/**
 * Standing authorizations with Spotify and YouTube.
 *
 * ## The shape of the flow
 *
 * ```
 *  app -- POST /music/connections/spotify/start ---------> this server
 *      <-- { authorizationUrl } -------------------------
 *
 *  app -- opens it in a system browser ------------------> Spotify
 *                        (user consents)
 *      <-- 302 to {PUBLIC_API_URL}/…/callback -----------  this server
 *                  code -> tokens, using the CLIENT SECRET
 *                  tokens -> sealed and stored against the uid
 *      --- 302 to aurix://music-callback?provider=spotify&status=connected
 *
 *  app -- POST /music/import { url } --------------------> this server
 *                  connection -> access token (refreshed if stale)
 *                  Spotify Web API -> playlist + items
 *      <-- the imported AURIX playlist ------------------
 * ```
 *
 * The provider's tokens never leave this process. The app learns only that a
 * connection exists — which is the whole of requirement §11, and the reason the
 * client secret can exist at all: there is nowhere to hide one in a Flutter
 * binary, and there does not need to be.
 *
 * ## Why the connection outlives the import
 *
 * The previous design authorized per import and cleared the session afterwards,
 * so every playlist meant another consent screen. A stored refresh token turns
 * that into a one-time "Connect Spotify", which is what §9 asks for. The cost
 * is that this module now owns a long-lived credential, which is why it is
 * encrypted at rest (`crypto.ts`) and why [disconnect] is offered prominently.
 */

const sha256 = (value: string) => crypto.createHash('sha256').update(value).digest('base64url');
const opaque = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');

/**
 * Renew this many seconds before the provider says the token dies.
 *
 * Not zero, and the reason is a real failure rather than caution: a token that
 * is valid when the import starts can lapse *during* a twelve-page fetch, and
 * the request that fails is then somewhere in the middle of a loop with half a
 * playlist in memory. Sixty seconds is comfortably longer than a page fetch and
 * short enough that it does not throw away most of an hour's validity.
 */
const REFRESH_SKEW_SECONDS = 60;

// ---------------------------------------------------------------------------
// Starting a connection
// ---------------------------------------------------------------------------

/** PKCE S256, per RFC 7636. Same construction as the sign-in flow. */
function pkcePair(): { verifier: string; challenge: string } {
  const verifier = opaque(48);
  const challenge = crypto.createHash('sha256').update(verifier).digest('base64url');
  return { verifier, challenge };
}

export const callbackUrlFor = (provider: MusicProviderId): string =>
  `${env.publicApiUrl}/api/v1/music/connections/${provider}/callback`;

/**
 * The app redirect this flow may finish at.
 *
 * Reuses `OAUTH_APP_REDIRECTS`, the same allow-list the sign-in flow checks
 * against, for the same reason: without one, `redirect_uri=https://attacker…`
 * turns this API into an open redirector. This flow carries no credential in
 * the final hop — the connection is already stored server-side by then, and the
 * redirect says only "connected" — but an unchecked redirect is still a phishing
 * surface, and the check costs nothing.
 */
function assertAllowedRedirect(redirectUri: string): string {
  const value = redirectUri.trim();
  if (!env.oauthAppRedirects.includes(value)) {
    throw badRequest(
      'That redirect address is not registered for this AURIX server. ' +
        'Add it to OAUTH_APP_REDIRECTS.',
    );
  }
  return value;
}

export interface BeginConnectResult {
  authorizationUrl: string;
  expiresInSeconds: number;
}

/**
 * Opens a consent round trip for [uid].
 *
 * The uid is written into the state document *here*, from the caller's verified
 * access token. The callback then reads it from that document and never from
 * anything the browser carries — which is what stops a crafted callback from
 * attaching one person's Spotify account to another person's AURIX account.
 */
export async function beginConnect({
  uid,
  provider: providerId,
  redirectUri,
}: {
  uid: string;
  provider: string;
  redirectUri: string;
}): Promise<BeginConnectResult> {
  const provider = requireMusicProvider(providerId);
  const appRedirect = assertAllowedRedirect(redirectUri);

  const state = opaque(24);
  const { verifier, challenge } = pkcePair();
  const now = Date.now();

  const states = await collections.musicAuthStates();
  await states.insertOne({
    state,
    provider: provider.id,
    uid,
    redirectUri: appRedirect,
    verifier,
    createdAt: new Date(now),
    expiresAt: new Date(now + env.oauthStateMinutes * 60 * 1000),
  });

  return {
    authorizationUrl: provider.authorizeUrl({
      state,
      redirectUri: callbackUrlFor(provider.id),
      codeChallenge: challenge,
    }),
    expiresInSeconds: env.oauthStateMinutes * 60,
  };
}

/** Consumes a state. A replayed callback finds nothing. */
export async function takeState(state: string): Promise<MusicAuthStateDoc> {
  if (!state) throw invalidAuthState();
  const states = await collections.musicAuthStates();
  const record = await states.findOneAndDelete({ state });
  if (!record) throw invalidAuthState();
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    throw invalidAuthState();
  }
  return record;
}

// ---------------------------------------------------------------------------
// Storing a connection
// ---------------------------------------------------------------------------

/**
 * Writes the connection, replacing whatever was there.
 *
 * An upsert on `(uid, provider)` rather than an insert, because re-connecting is
 * the common case — a user whose Google refresh token was revoked presses
 * Connect again, and that must update the row rather than collide with the
 * unique index.
 */
export async function storeConnection({
  uid,
  provider,
  tokens,
  account,
}: {
  uid: string;
  provider: MusicProviderId;
  tokens: TokenSet;
  account: { id: string; name: string };
}): Promise<void> {
  const now = new Date();
  const connections = await collections.musicConnections();

  await connections.updateOne(
    { uid, provider },
    {
      $set: {
        accessToken: seal(tokens.accessToken),
        // Only when the provider gave one. Spotify omits it on refresh and
        // Google omits it on a repeat consent without `prompt=consent`; writing
        // `undefined` over a good token is how a connection loses the ability
        // to renew itself.
        ...(tokens.refreshToken ? { refreshToken: seal(tokens.refreshToken) } : {}),
        expiresAt: new Date(Date.now() + tokens.expiresIn * 1000),
        scopes: tokens.scopes,
        accountId: account.id,
        accountName: account.name,
        updatedAt: now,
      },
      $setOnInsert: { uid, provider, createdAt: now },
    },
    { upsert: true },
  );

  log.info(`${provider} connected for ${uid}`, 'music');
}

// ---------------------------------------------------------------------------
// Using a connection
// ---------------------------------------------------------------------------

/**
 * A usable access token for [uid] on [provider], refreshing if it is stale.
 *
 * Returns null when there is no connection at all — the caller decides whether
 * that is fatal, because it is not always: a public YouTube playlist reads with
 * an API key and no connection whatsoever, and forcing a consent screen for one
 * would be exactly the friction §"Important clarification" rules out.
 *
 * Throws `provider_reconnect_required` when there *is* a connection that cannot
 * be renewed. The distinction between those two is the whole point of the
 * signature: "connect" and "reconnect" are different sentences to show a user.
 */
export async function credentialFor(
  uid: string,
  provider: MusicProviderId,
): Promise<ProviderCredential | null> {
  const connections = await collections.musicConnections();
  const doc = await connections.findOne({ uid, provider });
  if (!doc) return null;

  const label = musicProvider(provider).label;
  const freshEnough =
    doc.expiresAt instanceof Date &&
    doc.expiresAt.getTime() - REFRESH_SKEW_SECONDS * 1000 > Date.now();

  if (freshEnough) {
    const accessToken = open(doc.accessToken);
    // Null here means the encryption key changed under a live connection. The
    // token is unrecoverable, so the honest answer is "reconnect" rather than a
    // 500 the user cannot act on. See `crypto.open`.
    if (accessToken) {
      return { accessToken, scopes: doc.scopes ?? [], accountId: doc.accountId ?? '' };
    }
    log.warn(`Stored ${provider} token for ${uid} could not be decrypted`, 'music');
  }

  return refreshConnection(doc, label);
}

/** Renews a connection in place, or reports that it cannot be renewed. */
async function refreshConnection(
  doc: MusicConnectionDoc,
  label: string,
): Promise<ProviderCredential> {
  const refreshToken = open(doc.refreshToken);
  if (!refreshToken) {
    // Either the provider never issued one, or the key rotated. Both mean the
    // same thing to the user and both are recoverable by reconnecting.
    throw providerReconnectRequired(
      label,
      `Your ${label} connection can no longer be renewed. Reconnect ${label} and try again.`,
    );
  }

  const provider = requireMusicProvider(doc.provider);

  let tokens: TokenSet;
  try {
    tokens = await provider.refresh(refreshToken);
  } catch (error) {
    if (error instanceof OAuthError && error.isDeadGrant) {
      // The user revoked AURIX in their provider's app settings, or the grant
      // was invalidated. Delete the row: leaving it would make the UI keep
      // claiming "Connected" for something that can never work again.
      const connections = await collections.musicConnections();
      await connections.deleteOne({ uid: doc.uid, provider: doc.provider });
      log.info(`${doc.provider} grant for ${doc.uid} was revoked; connection removed`, 'music');
      throw providerReconnectRequired(
        label,
        `AURIX's access to your ${label} account was withdrawn. Reconnect ${label} to import.`,
      );
    }
    // A transport failure or provider outage. Not the user's doing, and not a
    // reason to tear down a working connection.
    throw error;
  }

  await storeConnection({
    uid: doc.uid,
    provider: doc.provider,
    tokens: {
      ...tokens,
      // Spotify usually omits it on refresh; keep the one that still works.
      refreshToken: tokens.refreshToken ?? refreshToken,
    },
    account: { id: doc.accountId ?? '', name: doc.accountName ?? '' },
  });

  log.info(`${doc.provider} token refreshed for ${doc.uid}`, 'music');
  return {
    accessToken: tokens.accessToken,
    scopes: tokens.scopes,
    accountId: doc.accountId ?? '',
  };
}

/**
 * A credential, or a refusal naming the button the user should press.
 *
 * For the providers and playlists where reading genuinely requires a user.
 */
export async function requireCredential(
  uid: string,
  provider: MusicProviderId,
): Promise<ProviderCredential> {
  const credential = await credentialFor(uid, provider);
  if (!credential) throw providerAuthRequired(musicProvider(provider).label);
  return credential;
}

// ---------------------------------------------------------------------------
// Reporting and removing
// ---------------------------------------------------------------------------

/** What the import screen renders for one provider. Carries no token. */
export interface ConnectionStatus {
  provider: MusicProviderId;
  label: string;
  connected: boolean;
  /** Whether "Connect" can run on this deployment at all. */
  configured: boolean;
  /** Whether a *public* playlist imports with no connection. */
  publicReads: boolean;
  accountName?: string;
  connectedAt?: string;
  /**
   * True when a connection exists but has no refresh token, so it will need
   * reconnecting once the access token lapses. Shown as a soft warning rather
   * than as "disconnected", because it works right now.
   */
  expiring?: boolean;
}

export async function connectionStatuses(uid: string): Promise<ConnectionStatus[]> {
  const connections = await collections.musicConnections();
  const rows = await connections.find({ uid }).toArray();
  const byProvider = new Map(rows.map((row) => [row.provider, row]));

  return musicProviders().map((capability) => {
    const row = byProvider.get(capability.id);
    return {
      provider: capability.id,
      label: musicProvider(capability.id).label,
      connected: Boolean(row),
      configured: capability.oauth,
      publicReads: capability.publicReads,
      ...(row?.accountName ? { accountName: row.accountName } : {}),
      ...(row?.createdAt ? { connectedAt: row.createdAt.toISOString() } : {}),
      ...(row && !row.refreshToken ? { expiring: true } : {}),
    };
  });
}

/**
 * Forgets the connection.
 *
 * Local only: it deletes AURIX's copy of the tokens and does **not** revoke the
 * grant at the provider. That is the correct scope for this button — the user
 * asked AURIX to forget them, and revoking centrally would also break any other
 * device signed in with the same account. The provider's own app settings page
 * is where a full revocation belongs, and both providers offer one.
 */
export async function disconnect(uid: string, provider: MusicProviderId): Promise<boolean> {
  const connections = await collections.musicConnections();
  const result = await connections.deleteOne({ uid, provider });
  if (result.deletedCount > 0) log.info(`${provider} disconnected for ${uid}`, 'music');
  return result.deletedCount > 0;
}

/** Whether a connection carries everything [scopes] needs. */
export const hasScopes = (credential: ProviderCredential, scopes: string[]): boolean =>
  scopes.every((scope) => credential.scopes.includes(scope));

export { sha256 };
