import { env, type MusicProviderId } from '../../config/env';
import { musicProviderUnavailable, unavailable } from '../../utils/errors';

/**
 * What each music provider's OAuth looks like, in one table.
 *
 * ## Why the two entries differ as much as they do
 *
 * They are answering the same question — "may AURIX read this account's
 * playlists?" — through two implementations that agree on almost nothing:
 *
 *  * **Spotify** authenticates the *client* with HTTP Basic on the token
 *    endpoint. It returns a refresh token on the first exchange and usually
 *    omits it on subsequent refreshes, meaning the original must be kept.
 *  * **Google** authenticates the client with form fields, and returns a
 *    refresh token **only** when `access_type=offline` is combined with
 *    `prompt=consent`. Omit either and a returning user gets an access token
 *    that expires in an hour and nothing to renew it with — the connection then
 *    appears to work and silently dies. That is why `prompt=consent` is forced
 *    below even though it re-asks a user who has already agreed.
 *
 * Those differences are the reason this is a table of behaviours rather than
 * one parameterised URL builder.
 */

export interface TokenSet {
  accessToken: string;
  refreshToken?: string;
  /** Seconds until [accessToken] lapses, as the provider reports it. */
  expiresIn: number;
  /** What was actually granted, which is not always what was asked for. */
  scopes: string[];
}

export interface ProviderAccount {
  id: string;
  name: string;
}

export interface MusicProviderDefinition {
  id: MusicProviderId;
  /** How the provider is named in messages the user reads. */
  label: string;
  scopes: string[];
  authorizeUrl(input: { state: string; redirectUri: string; codeChallenge: string }): string;
  exchange(input: { code: string; redirectUri: string; verifier: string }): Promise<TokenSet>;
  refresh(refreshToken: string): Promise<TokenSet>;
  /** Identifies the connected account, so the UI can say whose it is. */
  identify(accessToken: string): Promise<ProviderAccount>;
}

// ---------------------------------------------------------------------------
// Shared HTTP
// ---------------------------------------------------------------------------

/**
 * A token-endpoint call, with the failure modes named.
 *
 * OAuth token endpoints answer 400 with a JSON `error` for conditions that are
 * emphatically not "bad request" from the user's point of view —
 * `invalid_grant` in particular means "that refresh token is dead", which is
 * the single most important thing this module has to be able to report. So the
 * body is parsed and the code is carried out rather than flattened into a
 * status.
 */
async function postForm(url: string, form: URLSearchParams, headers: Record<string, string> = {}) {
  let response: Response;
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded', ...headers },
      body: form,
    });
  } catch (error) {
    // DNS, TLS, or the provider being down. Not the user's problem and not a
    // reason to tell them to reconnect.
    throw unavailable(
      `Could not reach the authorization service. ${
        error instanceof Error ? error.message : ''
      }`.trim(),
    );
  }

  const text = await response.text();
  let payload: Record<string, unknown> = {};
  try {
    payload = text ? (JSON.parse(text) as Record<string, unknown>) : {};
  } catch {
    // Some providers answer a plain-text error page on a 5xx.
    payload = { error: 'invalid_response', error_description: text.slice(0, 300) };
  }

  if (!response.ok) {
    const error = new OAuthError(
      String(payload.error ?? `http_${response.status}`),
      String(payload.error_description ?? payload.error ?? `HTTP ${response.status}`),
    );
    throw error;
  }

  return payload;
}

/**
 * A failure reported *by the provider's own token endpoint*.
 *
 * Carries the OAuth error code so `connections.ts` can distinguish a revoked
 * grant — which needs the user to reconnect — from a transport blip, which
 * needs a retry. Collapsing the two is what produces "reconnect Spotify"
 * messages during an outage.
 */
export class OAuthError extends Error {
  readonly code: string;

  constructor(code: string, message: string) {
    super(message);
    this.name = 'OAuthError';
    this.code = code;
  }

  /** True when the grant is gone for good and only re-consent recovers it. */
  get isDeadGrant(): boolean {
    return this.code === 'invalid_grant' || this.code === 'unauthorized_client';
  }
}

const tokenSetFrom = (payload: Record<string, unknown>, requested: string[]): TokenSet => ({
  accessToken: String(payload.access_token ?? ''),
  refreshToken:
    typeof payload.refresh_token === 'string' && payload.refresh_token
      ? payload.refresh_token
      : undefined,
  expiresIn: Number(payload.expires_in ?? 3600),
  // Both providers echo a space-separated `scope`. When one does not, assuming
  // what was asked for is the only available answer — and it is the optimistic
  // one, so the scope check downstream stays a fast-fail rather than a gate
  // that blocks a working connection.
  scopes:
    typeof payload.scope === 'string' && payload.scope.trim()
      ? payload.scope.trim().split(/\s+/)
      : requested,
});

// ---------------------------------------------------------------------------
// Spotify
// ---------------------------------------------------------------------------

/**
 * The scopes an import actually needs — and no more.
 *
 * The mobile app's own `SpotifyScopes.all` asks for sixteen, because it also
 * plays music, reads the library and follows artists. This connection reads
 * playlists and nothing else, so it asks for three. A consent screen listing
 * "control playback" for a feature that imports a track list is both a worse
 * experience and a larger blast radius than it needs to be.
 *
 *  * `playlist-read-private` — the user's own playlists, public or not.
 *  * `playlist-read-collaborative` — playlists they collaborate on but do not
 *    own. Since February 2026 these are the *only* two categories whose items
 *    Spotify will serve at all; see `spotify.ts`.
 *  * `user-read-private` — so `GET /me` can name the connected account, which
 *    is what lets the ownership error say "you are connected as X".
 */
const SPOTIFY_SCOPES = [
  'playlist-read-private',
  'playlist-read-collaborative',
  'user-read-private',
];

const spotify: MusicProviderDefinition = {
  id: 'spotify',
  label: 'Spotify',
  scopes: SPOTIFY_SCOPES,

  authorizeUrl: ({ state, redirectUri, codeChallenge }) => {
    const url = new URL('https://accounts.spotify.com/authorize');
    url.searchParams.set('client_id', env.music.spotify.clientId);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('redirect_uri', redirectUri);
    url.searchParams.set('state', state);
    url.searchParams.set('scope', SPOTIFY_SCOPES.join(' '));
    // PKCE on top of the client secret. Belt and braces: the secret already
    // authenticates the exchange, and the challenge additionally binds the code
    // to the browser that started the flow, so an intercepted redirect is not
    // redeemable elsewhere.
    url.searchParams.set('code_challenge_method', 'S256');
    url.searchParams.set('code_challenge', codeChallenge);
    return url.toString();
  },

  exchange: async ({ code, redirectUri, verifier }) => {
    const payload = await postForm(
      'https://accounts.spotify.com/api/token',
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri,
        code_verifier: verifier,
      }),
      { authorization: spotifyBasicAuth() },
    );
    return tokenSetFrom(payload, SPOTIFY_SCOPES);
  },

  refresh: async (refreshToken) => {
    const payload = await postForm(
      'https://accounts.spotify.com/api/token',
      new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken }),
      { authorization: spotifyBasicAuth() },
    );
    // Spotify usually omits `refresh_token` here. `tokenSetFrom` leaves it
    // undefined and the caller keeps the one it already has — overwriting with
    // undefined is how a connection loses the ability to renew itself and dies
    // an hour later.
    return tokenSetFrom(payload, SPOTIFY_SCOPES);
  },

  identify: async (accessToken) => {
    const response = await fetch('https://api.spotify.com/v1/me', {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) {
      throw new OAuthError(
        `http_${response.status}`,
        `Spotify would not identify the connected account (HTTP ${response.status}).`,
      );
    }
    const me = (await response.json()) as Record<string, unknown>;
    const id = String(me.id ?? '');
    return { id, name: String(me.display_name ?? '') || id };
  },
};

/**
 * `Authorization: Basic base64(client_id:client_secret)`.
 *
 * Spotify documents both this and client credentials in the form body; Basic is
 * what it prefers, and it keeps the secret out of anything that logs request
 * bodies.
 */
function spotifyBasicAuth(): string {
  const { clientId, clientSecret } = env.music.spotify;
  return `Basic ${Buffer.from(`${clientId}:${clientSecret}`).toString('base64')}`;
}

// ---------------------------------------------------------------------------
// YouTube (Google)
// ---------------------------------------------------------------------------

/**
 * Read-only access to the user's YouTube account.
 *
 * `youtube.readonly` covers listing a playlist the user owns and its items,
 * including private and unlisted ones. There is deliberately no write scope:
 * AURIX imports *from* YouTube and never modifies anything there.
 */
const YOUTUBE_SCOPES = ['https://www.googleapis.com/auth/youtube.readonly'];

const youtube: MusicProviderDefinition = {
  id: 'youtube',
  label: 'YouTube',
  scopes: YOUTUBE_SCOPES,

  authorizeUrl: ({ state, redirectUri, codeChallenge }) => {
    const url = new URL('https://accounts.google.com/o/oauth2/v2/auth');
    url.searchParams.set('client_id', env.music.youtube.clientId);
    url.searchParams.set('response_type', 'code');
    url.searchParams.set('redirect_uri', redirectUri);
    url.searchParams.set('state', state);
    url.searchParams.set('scope', YOUTUBE_SCOPES.join(' '));
    // Without this pair there is no refresh token, and the connection lasts an
    // hour. See the note at the top of this file — `prompt=consent` re-asks a
    // user who has already agreed, and that is the lesser evil.
    url.searchParams.set('access_type', 'offline');
    url.searchParams.set('prompt', 'consent');
    url.searchParams.set('code_challenge_method', 'S256');
    url.searchParams.set('code_challenge', codeChallenge);
    return url.toString();
  },

  exchange: async ({ code, redirectUri, verifier }) => {
    const payload = await postForm(
      'https://oauth2.googleapis.com/token',
      new URLSearchParams({
        grant_type: 'authorization_code',
        code,
        redirect_uri: redirectUri,
        code_verifier: verifier,
        client_id: env.music.youtube.clientId,
        client_secret: env.music.youtube.clientSecret,
      }),
    );
    return tokenSetFrom(payload, YOUTUBE_SCOPES);
  },

  refresh: async (refreshToken) => {
    const payload = await postForm(
      'https://oauth2.googleapis.com/token',
      new URLSearchParams({
        grant_type: 'refresh_token',
        refresh_token: refreshToken,
        client_id: env.music.youtube.clientId,
        client_secret: env.music.youtube.clientSecret,
      }),
    );
    return tokenSetFrom(payload, YOUTUBE_SCOPES);
  },

  identify: async (accessToken) => {
    // The *channel*, not the Google account. A YouTube playlist belongs to a
    // channel, and a Google account can hold several — so the channel id is the
    // one that can be compared against a playlist's owner.
    const url = new URL('https://www.googleapis.com/youtube/v3/channels');
    url.searchParams.set('part', 'snippet');
    url.searchParams.set('mine', 'true');

    const response = await fetch(url, {
      headers: { authorization: `Bearer ${accessToken}` },
    });
    if (!response.ok) {
      throw new OAuthError(
        `http_${response.status}`,
        `Google would not identify the connected account (HTTP ${response.status}).`,
      );
    }

    const body = (await response.json()) as {
      items?: { id?: string; snippet?: { title?: string } }[];
    };
    const channel = body.items?.[0];
    // A Google account with no YouTube channel is a real state — it can still
    // read public playlists, so this is not an error, just an unnamed account.
    return {
      id: channel?.id ?? '',
      name: channel?.snippet?.title ?? 'YouTube account',
    };
  },
};

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

const REGISTRY: Record<MusicProviderId, MusicProviderDefinition> = { spotify, youtube };

export const isMusicProviderId = (value: string): value is MusicProviderId =>
  value === 'spotify' || value === 'youtube';

/** The definition for [id], or a 503 naming what the deployment is missing. */
export function requireMusicProvider(id: string): MusicProviderDefinition {
  if (!isMusicProviderId(id)) throw musicProviderUnavailable(id);

  const credentials = env.music[id];
  if (!credentials.clientId || !credentials.clientSecret) {
    throw musicProviderUnavailable(REGISTRY[id].label);
  }
  if (!env.publicApiUrl) {
    // A provider cannot redirect a browser back to a deployment with no public
    // address. Failing here with the reason beats sending the user to a consent
    // screen that lands nowhere.
    throw unavailable(
      'This AURIX server has no PUBLIC_API_URL set, so it cannot complete a ' +
        'provider sign-in. Set it and try again.',
    );
  }
  return REGISTRY[id];
}

/** The definition for [id] without the configuration check. For labels only. */
export const musicProvider = (id: MusicProviderId): MusicProviderDefinition => REGISTRY[id];
