import {
  providerForbidden,
  providerNotFound,
  providerRateLimited,
  providerReconnectRequired,
  unavailable,
} from '../../utils/errors';
import { log } from '../../utils/logger';
import { spotifyPlaylistUrl } from './links';
import type {
  FetchedPlaylist,
  PlaylistFetcher,
  ProviderCredential,
  ProviderPlaylist,
  ProviderTrack,
  SkippedEntry,
} from './types';

/**
 * Reading a Spotify playlist.
 *
 * ## The bug this file exists to fix, stated precisely
 *
 * The symptom was a log that read:
 *
 * ```
 * [aurix.http] → GET /playlists/22WMPdyCLdKfeRraLxZbMw
 * [aurix.http] ← 200 /playlists/22WMPdyCLdKfeRraLxZbMw
 * [aurix.playlist] Contents unavailable — Spotify refused both /items and /tracks
 * ```
 *
 * Two separate causes were tangled together in it.
 *
 * **1. `/playlists/{id}/tracks` no longer exists.** Spotify's February 2026
 * changes removed it, along with the `POST`, `PUT` and `DELETE` on the same
 * path, and replaced all four with `/playlists/{id}/items`. Enforcement landed
 * on **9 March 2026**, after which the old path answers `403` to every caller.
 * The old client tried `/items` first and then fell back to `/tracks`, so the
 * fallback could never do anything except turn one failure into two and produce
 * the "refused both" wording. There is no fallback here: the removed endpoint is
 * not called, because an endpoint that answers 403 to everyone is not a
 * candidate, it is noise in a log.
 *
 * **2. `/playlists/{id}/items` is not a public endpoint.** This is the part the
 * old design got structurally wrong, and no amount of fixing the authorization
 * flow changes it. Spotify's own reference says:
 *
 * > "This endpoint is only accessible for playlists owned by the current user
 * > or playlists the user is a collaborator of." — and a "403 Forbidden status
 * > code will be returned if the user is neither the owner nor a collaborator
 * > of the playlist."
 *
 * Meanwhile `GET /playlists/{id}` still answers `200` with metadata for *any*
 * playlist. That asymmetry is the entire symptom: the app could see the
 * playlist's name, cover and track count, and could not read a single track.
 * It looked like a broken request. It was a policy.
 *
 * So the honest contract is: **AURIX can import a Spotify playlist that the
 * connected account owns or collaborates on, and cannot import anyone else's.**
 * [ownershipRefusal] is what says that to the user, naming the account they are
 * connected as, rather than reporting "contents unavailable" and leaving them to
 * guess. Scraping the web player would route around the refusal, and is not
 * something this codebase does.
 *
 * ## Paging
 *
 * `next` is followed until it is null. Spotify returns it as an absolute URL, so
 * it is used verbatim rather than recomputed from an offset — an offset walk
 * re-derives what the server already answered and drifts if the playlist is
 * edited mid-fetch.
 */

const API = 'https://api.spotify.com/v1';

/** Spotify's maximum for this endpoint. */
const PAGE_SIZE = 50;

/**
 * A ceiling on one import.
 *
 * Spotify permits 10,000 items in a playlist. Importing one would be 200
 * requests and 10,000 catalogue upserts with the user watching a progress bar.
 * High enough that no ordinary playlist reaches it; low enough that a
 * pathological one cannot run for an hour. When it is hit the result is
 * reported as `truncated` rather than silently cut short.
 */
const MAX_TRACKS = 2000;

/** Spotify's own editorial and algorithmic namespace. */
const EDITORIAL_PREFIX = '37i9dQZF1';

export const isEditorialPlaylist = (id: string): boolean => id.startsWith(EDITORIAL_PREFIX);

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

interface SpotifyResponse<T> {
  status: number;
  body: T;
}

async function call<T>(url: string, accessToken: string): Promise<SpotifyResponse<T>> {
  let response: Response;
  try {
    response = await fetch(url, {
      headers: { authorization: `Bearer ${accessToken}` },
    });
  } catch (error) {
    throw unavailable(
      `Could not reach Spotify. ${error instanceof Error ? error.message : ''}`.trim(),
    );
  }

  if (response.status === 429) {
    // Spotify's Retry-After is in seconds and is authoritative — it is not a
    // suggestion, and ignoring it is how an application earns a longer ban.
    throw providerRateLimited('Spotify', Number(response.headers.get('retry-after') ?? '5'));
  }

  if (response.status === 401) {
    // The token was refreshed moments ago by `credentialFor`, so a 401 here is
    // a revoked grant rather than an expiry — the user removed AURIX from their
    // Spotify app settings mid-flight.
    throw providerReconnectRequired('Spotify');
  }

  const text = await response.text();
  let body: unknown = null;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }

  return { status: response.status, body: body as T };
}

/** The message Spotify put in the envelope, when it put one there. */
function spotifyMessage(body: unknown): string {
  const error = (body as { error?: { message?: string } } | null)?.error;
  return typeof error?.message === 'string' ? error.message : '';
}

// ---------------------------------------------------------------------------
// Response shapes
// ---------------------------------------------------------------------------

interface SpotifyImage {
  url?: string;
  width?: number | null;
}

interface SpotifyArtist {
  id?: string;
  name?: string;
}

interface SpotifyTrackObject {
  id?: string | null;
  name?: string;
  type?: string;
  duration_ms?: number;
  explicit?: boolean;
  preview_url?: string | null;
  artists?: SpotifyArtist[];
  album?: { name?: string; images?: SpotifyImage[] };
  external_urls?: { spotify?: string };
  is_local?: boolean;
}

/**
 * One entry in a playlist.
 *
 * Carries **both** `item` and `track`. February 2026 renamed
 * `items.items.track` to `items.items.item`, and Spotify's reference now marks
 * `track` as deprecated with "Use `item` instead" — while still returning it.
 * Reading only `track` is a bug with a fuse on it: it works today and produces a
 * playlist of nothing on the day Spotify drops the compatibility field. Reading
 * only `item` breaks against any deployment still serving the old shape. So
 * both are read, `item` first.
 */
interface SpotifyPlaylistEntry {
  item?: SpotifyTrackObject | null;
  track?: SpotifyTrackObject | null;
  is_local?: boolean;
}

interface SpotifyPage<T> {
  items?: T[];
  next?: string | null;
  total?: number;
}

interface SpotifyPlaylistObject {
  id?: string;
  name?: string;
  description?: string;
  images?: SpotifyImage[];
  owner?: { id?: string; display_name?: string };
  external_urls?: { spotify?: string };
  /** The post-rename container. */
  items?: { total?: number };
  /** The pre-rename container, still sent by some deployments. */
  tracks?: { total?: number };
}

// ---------------------------------------------------------------------------
// Fetcher
// ---------------------------------------------------------------------------

export const spotifyFetcher: PlaylistFetcher = {
  provider: 'spotify',
  label: 'Spotify',

  async fetch(playlistId, credential): Promise<FetchedPlaylist> {
    if (!credential) {
      // Unreachable through the import route, which requires a credential for
      // Spotify. Stated anyway: there is no unauthenticated read path on the
      // Spotify Web API at all, so a null credential is a programming error and
      // should not be silently treated as "public".
      throw providerReconnectRequired(
        'Spotify',
        'Connect Spotify to import a playlist from it.',
      );
    }

    const playlist = await fetchMetadata(playlistId, credential);
    const { tracks, skipped, truncated } = await fetchItems(playlistId, credential, playlist);

    return { playlist, tracks, skipped, truncated };
  },
};

async function fetchMetadata(
  playlistId: string,
  credential: ProviderCredential,
): Promise<ProviderPlaylist> {
  const url = new URL(`${API}/playlists/${playlistId}`);
  // Only the fields that are actually used. Spotify's default response inlines
  // the first page of items, which this does not want — it is fetched properly,
  // with paging, by `fetchItems`, and asking for it twice is a wasted transfer.
  url.searchParams.set(
    'fields',
    'id,name,description,images,owner(id,display_name),external_urls,items(total),tracks(total)',
  );

  const { status, body } = await call<SpotifyPlaylistObject>(url.toString(), credential.accessToken);

  if (status === 404) {
    throw providerNotFound(
      isEditorialPlaylist(playlistId)
        ? 'That is one of Spotify’s own editorial playlists (Discover Weekly, ' +
            'Today’s Top Hits and similar). Spotify does not serve those to ' +
            'third-party applications, so AURIX cannot import it.'
        : 'That Spotify playlist does not exist, or has been deleted.',
    );
  }

  if (status === 403) {
    throw providerForbidden(
      'Spotify will not show that playlist to AURIX. It is most likely private ' +
        'and belongs to another account.',
    );
  }

  if (status < 200 || status >= 300 || !body) {
    throw unavailable(
      `Spotify could not return that playlist (HTTP ${status}). ${spotifyMessage(body)}`.trim(),
    );
  }

  return {
    providerPlaylistId: body.id ?? playlistId,
    name: body.name?.trim() || 'Untitled playlist',
    description: plainText(body.description ?? ''),
    coverUrl: largestImage(body.images),
    ownerName: body.owner?.display_name?.trim() || body.owner?.id?.trim() || '',
    // Post-rename first, pre-rename second. Advisory either way — `import.ts`
    // counts the rows it actually wrote.
    totalTracks: body.items?.total ?? body.tracks?.total ?? 0,
    externalUrl: body.external_urls?.spotify || spotifyPlaylistUrl(playlistId),
  };
}

async function fetchItems(
  playlistId: string,
  credential: ProviderCredential,
  playlist: ProviderPlaylist,
): Promise<{ tracks: ProviderTrack[]; skipped: SkippedEntry[]; truncated: boolean }> {
  const tracks: ProviderTrack[] = [];
  const skipped: SkippedEntry[] = [];
  let position = 0;
  let truncated = false;

  const first = new URL(`${API}/playlists/${playlistId}/items`);
  first.searchParams.set('limit', String(PAGE_SIZE));
  first.searchParams.set('offset', '0');
  // Keeps podcast episodes out of `items`; without it they arrive as objects
  // with no artist and a duration, and render as songs that cannot be played.
  first.searchParams.set('additional_types', 'track');

  let next: string | null = first.toString();
  let pages = 0;

  while (next) {
    const { status, body }: SpotifyResponse<SpotifyPage<SpotifyPlaylistEntry>> = await call(
      next,
      credential.accessToken,
    );

    if (status === 403) throw ownershipRefusal(playlistId, credential, playlist);

    if (status === 404) {
      throw providerNotFound(
        'Spotify stopped serving that playlist part-way through the import. It ' +
          'may have been deleted while AURIX was reading it.',
      );
    }

    if (status < 200 || status >= 300 || !body) {
      throw unavailable(
        `Spotify could not return that playlist's tracks (HTTP ${status}). ${spotifyMessage(
          body,
        )}`.trim(),
      );
    }

    // Guarded rather than `body.items ?? []`: on the playlist *object* the key
    // `items` is a paging container, not an array, so a response that arrived
    // from the wrong endpoint would throw a TypeError mid-import instead of
    // being reported. Cheap insurance on a value that comes off the network.
    for (const entry of Array.isArray(body.items) ? body.items : []) {
      position += 1;

      // `item` is the current spelling; `track` is the deprecated one Spotify
      // still sends. See the note on SpotifyPlaylistEntry.
      const source = entry.item ?? entry.track ?? null;
      const isLocal = entry.is_local === true || source?.is_local === true;

      if (!source) {
        // Spotify sends a null entry for a track removed from its catalogue.
        // Recorded rather than dropped, so a playlist of 40 that imports 37 can
        // say why.
        skipped.push({ position, reason: 'deleted' });
        continue;
      }
      if (isLocal) {
        // A local file on the user's own machine. It has no id, cannot be
        // looked up, and there is nothing for AURIX to store.
        skipped.push({ position, reason: 'local_file' });
        continue;
      }
      if (source.type && source.type !== 'track') {
        skipped.push({ position, reason: 'not_a_track' });
        continue;
      }
      if (!source.id) {
        // An empty id would collide with every other empty id in the catalogue
        // key and merge unrelated songs into one document.
        skipped.push({ position, reason: 'no_id' });
        continue;
      }

      tracks.push(describe(source));

      if (tracks.length >= MAX_TRACKS) {
        truncated = true;
        break;
      }
    }

    if (truncated) break;

    // `next` is an absolute URL Spotify computed. Used verbatim rather than
    // rebuilt from an offset: the server already answered where the next page
    // is, and an offset walk drifts if the playlist is edited mid-fetch.
    next = body.next ?? null;

    // A defensive stop. If a future response ever returned a `next` that
    // pointed at itself, this is what keeps the import from running until the
    // function times out.
    pages += 1;
    if (pages > Math.ceil(MAX_TRACKS / PAGE_SIZE) + 2) {
      log.warn(`Spotify paging for ${playlistId} did not terminate; stopping`, 'music');
      truncated = true;
      break;
    }
  }

  return { tracks, skipped, truncated };
}

/**
 * The message for the refusal that matters.
 *
 * Reached when Spotify serves the playlist's metadata and refuses its items,
 * which since February 2026 means one thing: the connected account is neither
 * the owner nor a collaborator. Naming the account is what makes this
 * actionable — the commonest cause is being connected as the wrong one of two
 * Spotify accounts, and a user cannot see which one AURIX holds.
 */
function ownershipRefusal(
  playlistId: string,
  credential: ProviderCredential,
  playlist: ProviderPlaylist,
): never {
  if (isEditorialPlaylist(playlistId)) {
    throw providerForbidden(
      'That is one of Spotify’s own editorial playlists. Spotify does not ' +
        'let third-party applications read what is in them, so AURIX cannot ' +
        'import it. Copy the songs into a playlist of your own and import that.',
    );
  }

  const owner = playlist.ownerName ? `“${playlist.name}” belongs to ${playlist.ownerName}` : 'That playlist belongs to another account';
  const connectedAs = credential.accountId ? ` You are connected to Spotify as ${credential.accountId}.` : '';

  throw providerForbidden(
    `${owner}. Since February 2026 Spotify only lets an application read the ` +
      `songs in a playlist its own user owns or collaborates on, so AURIX ` +
      `cannot import this one.${connectedAs} If it is yours, connect the ` +
      `Spotify account that owns it; otherwise save a copy to your own library ` +
      `in Spotify and import that.`,
  );
}

// ---------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------

function describe(track: SpotifyTrackObject): ProviderTrack {
  const id = String(track.id ?? '');
  return {
    providerTrackId: id,
    title: track.name?.trim() || 'Unknown track',
    artists: (track.artists ?? [])
      .map((artist) => artist.name?.trim() ?? '')
      .filter((name) => name.length > 0),
    album: track.album?.name?.trim() ?? '',
    durationMs: Number.isFinite(track.duration_ms) ? Number(track.duration_ms) : 0,
    artworkUrl: largestImage(track.album?.images),
    explicit: track.explicit === true,
    externalUrl: track.external_urls?.spotify || `https://open.spotify.com/track/${id}`,
    // A 30-second clip Spotify itself publishes, and the only audio URL that
    // legitimately exists. Null for applications registered after 27 November
    // 2024, which is most of them now.
    ...(track.preview_url ? { previewUrl: track.preview_url } : {}),
  };
}

/**
 * The largest image, which is the first one Spotify lists.
 *
 * Spotify orders images widest-first. Taking `[0]` rather than sorting relies on
 * that, so it is checked: an entry with no width sorts as unknown rather than as
 * zero, which would otherwise pick the thumbnail.
 */
function largestImage(images: SpotifyImage[] | undefined): string {
  if (!images || images.length === 0) return '';
  const best = [...images].sort((a, b) => (b.width ?? 0) - (a.width ?? 0))[0];
  return best?.url ?? '';
}

/**
 * Strips the HTML Spotify allows inside a playlist description.
 *
 * Done here rather than at render time because this string is about to be
 * written to MongoDB and read back by screens that render it as plain text.
 */
function plainText(value: string): string {
  if (!value) return '';
  return value
    .replace(/<[^>]*>/g, '')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#x27;|&#39;/g, "'")
    .trim();
}
