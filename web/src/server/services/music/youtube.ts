import { env } from '../../config/env';
import {
  providerAuthRequired,
  providerForbidden,
  providerNotFound,
  providerRateLimited,
  providerReconnectRequired,
  unavailable,
} from '../../utils/errors';
import { log } from '../../utils/logger';
import { youtubePlaylistUrl } from './links';
import type {
  FetchedPlaylist,
  PlaylistFetcher,
  ProviderCredential,
  ProviderPlaylist,
  ProviderTrack,
  SkippedEntry,
} from './types';

/**
 * Reading a YouTube or YouTube Music playlist.
 *
 * ## YouTube Music is YouTube
 *
 * A `music.youtube.com/playlist?list=PL…` link and a
 * `youtube.com/playlist?list=PL…` link name the *same playlist with the same
 * id*, and the YouTube Data API serves it. That is what makes this importable
 * through an official API at all, and it is why `links.ts` treats both hosts as
 * one provider rather than inventing a third.
 *
 * There is no YouTube **Music** API. The private endpoints the web player uses
 * are not published, and scraping them is what §5 rules out — so the honest
 * boundary is: what the Data API serves, AURIX imports; what it does not,
 * AURIX refuses with the reason. Two things fall on the wrong side of that line
 * and both are refused by name rather than silently returning nothing:
 *
 *  * **Liked videos (`LL`) and Watch Later (`WL`)** — the API returns an empty
 *    page for these even with `youtube.readonly` granted. Refused in
 *    `links.ts`, before a request is made.
 *  * **Auto-generated "My Mix" / radio playlists (`RD…`)** — these are
 *    generated per-session and `playlists.list` does not resolve them. They
 *    surface as a 404 here and are named as such.
 *
 * ## Public playlists need no connection
 *
 * Unlike Spotify — where every call needs a token and a playlist's items need
 * the *owner's* token — YouTube serves a public playlist to a caller carrying
 * only an API key. So [youtubeFetcher] accepts a null credential and uses the
 * key, and only asks the user to connect when the key gets a 403 or 404, which
 * is what a private or unlisted playlist looks like from outside. That ordering
 * is the whole of the "authorize only when you need to" requirement.
 */

const API = 'https://www.googleapis.com/youtube/v3';

/** The API's maximum for both list endpoints. */
const PAGE_SIZE = 50;

/** `videos.list` accepts 50 ids per call. */
const DETAIL_BATCH = 50;

/** The same ceiling as Spotify, for the same reasons. */
const MAX_TRACKS = 2000;

/**
 * Titles YouTube substitutes for videos the caller may not see.
 *
 * The API does not flag these — it returns an ordinary item whose title is one
 * of these strings and whose `videoOwnerChannelTitle` is absent. Matching on the
 * title is unattractive and is the only signal there is; the absent channel is
 * checked alongside it so an actual song called "Private video" is not dropped.
 */
const HIDDEN_TITLES = new Set(['Private video', 'Deleted video', 'This video is unavailable']);

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

interface YouTubeResponse<T> {
  status: number;
  body: T | null;
  /** Google's machine-readable reason, e.g. `playlistNotFound`, `quotaExceeded`. */
  reason: string;
  message: string;
}

async function call<T>(
  url: URL,
  credential: ProviderCredential | null,
): Promise<YouTubeResponse<T>> {
  const headers: Record<string, string> = {};

  if (credential) {
    headers.authorization = `Bearer ${credential.accessToken}`;
  } else {
    // The key path. Public data only — see the note at the top.
    url.searchParams.set('key', env.music.youtube.apiKey);
  }

  let response: Response;
  try {
    response = await fetch(url, { headers });
  } catch (error) {
    throw unavailable(
      `Could not reach YouTube. ${error instanceof Error ? error.message : ''}`.trim(),
    );
  }

  const text = await response.text();
  let parsed: unknown = null;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = null;
  }

  const error = (parsed as { error?: { message?: string; errors?: { reason?: string }[] } } | null)
    ?.error;
  const reason = error?.errors?.[0]?.reason ?? '';
  const message = error?.message ?? '';

  // Google reports quota exhaustion as 403 with a specific reason, not 429. It
  // is emphatically not a permission problem, and reporting it as one would
  // send the user to reconnect an account that is working fine.
  if (reason === 'quotaExceeded' || reason === 'rateLimitExceeded' || response.status === 429) {
    throw providerRateLimited('YouTube', 60);
  }

  if (response.status === 401) {
    throw providerReconnectRequired('YouTube');
  }

  return { status: response.status, body: parsed as T | null, reason, message };
}

// ---------------------------------------------------------------------------
// Response shapes
// ---------------------------------------------------------------------------

interface Thumbnail {
  url?: string;
  width?: number;
}

interface Thumbnails {
  [key: string]: Thumbnail | undefined;
}

interface PlaylistResource {
  id?: string;
  snippet?: {
    title?: string;
    description?: string;
    channelId?: string;
    channelTitle?: string;
    thumbnails?: Thumbnails;
  };
  contentDetails?: { itemCount?: number };
}

interface PlaylistItemResource {
  snippet?: {
    title?: string;
    videoOwnerChannelTitle?: string;
    thumbnails?: Thumbnails;
    resourceId?: { kind?: string; videoId?: string };
  };
  contentDetails?: { videoId?: string };
}

interface VideoResource {
  id?: string;
  contentDetails?: { duration?: string };
  snippet?: { title?: string; channelTitle?: string };
}

interface ListResponse<T> {
  items?: T[];
  nextPageToken?: string;
  pageInfo?: { totalResults?: number };
}

// ---------------------------------------------------------------------------
// Fetcher
// ---------------------------------------------------------------------------

export const youtubeFetcher: PlaylistFetcher = {
  provider: 'youtube',
  label: 'YouTube',

  async fetch(playlistId, credential): Promise<FetchedPlaylist> {
    if (!credential && !env.music.youtube.apiKey) {
      // No key and no connection: nothing can be read at all.
      throw providerAuthRequired('YouTube');
    }

    const playlist = await fetchMetadata(playlistId, credential);
    const { entries, skipped, truncated } = await fetchItems(playlistId, credential);
    const tracks = await resolveDurations(entries, credential);

    return { playlist, tracks, skipped, truncated };
  },
};

async function fetchMetadata(
  playlistId: string,
  credential: ProviderCredential | null,
): Promise<ProviderPlaylist> {
  const url = new URL(`${API}/playlists`);
  url.searchParams.set('part', 'snippet,contentDetails');
  url.searchParams.set('id', playlistId);

  const { status, body, message } = await call<ListResponse<PlaylistResource>>(url, credential);

  if (status === 403) throw notVisible(credential, message);

  if (status < 200 || status >= 300) {
    throw unavailable(`YouTube could not return that playlist (HTTP ${status}). ${message}`.trim());
  }

  const resource = body?.items?.[0];

  // An empty `items` array with a 200 is how the Data API says "no such
  // playlist, or you may not see it". Which of the two it means depends
  // entirely on whether a user is connected, and the two need different
  // sentences — that branch is the point of this block.
  if (!resource) {
    if (!credential) throw notVisible(null, message);
    if (playlistId.startsWith('RD')) {
      throw providerNotFound(
        'That is one of YouTube’s automatically generated mixes (My Mix, radio ' +
          'or "Start radio"). YouTube builds those per listening session and ' +
          'does not publish them, so there is nothing for AURIX to import. ' +
          'Save the songs to a playlist of your own and import that.',
      );
    }
    throw providerNotFound('That YouTube playlist does not exist, or has been deleted.');
  }

  return {
    providerPlaylistId: resource.id ?? playlistId,
    name: resource.snippet?.title?.trim() || 'Untitled playlist',
    description: (resource.snippet?.description ?? '').trim(),
    coverUrl: bestThumbnail(resource.snippet?.thumbnails),
    ownerName: resource.snippet?.channelTitle?.trim() ?? '',
    totalTracks: resource.contentDetails?.itemCount ?? 0,
    externalUrl: youtubePlaylistUrl(resource.id ?? playlistId),
  };
}

/**
 * "You cannot see this playlist" — with the remedy that fits.
 *
 * The distinction is the one §10 asks for: an unconnected caller is told to
 * connect, because connecting may genuinely fix it; a connected caller is told
 * the playlist is not theirs, because connecting again will not.
 */
function notVisible(credential: ProviderCredential | null, detail: string): never {
  if (!credential) {
    throw providerAuthRequired('YouTube');
  }
  throw providerForbidden(
    'That playlist is private and does not belong to the YouTube account ' +
      `AURIX is connected to.${detail ? ` YouTube said: ${detail}` : ''}`,
  );
}

interface PendingTrack {
  videoId: string;
  title: string;
  channel: string;
  artworkUrl: string;
}

async function fetchItems(
  playlistId: string,
  credential: ProviderCredential | null,
): Promise<{ entries: PendingTrack[]; skipped: SkippedEntry[]; truncated: boolean }> {
  const entries: PendingTrack[] = [];
  const skipped: SkippedEntry[] = [];
  let pageToken: string | undefined;
  let position = 0;
  let truncated = false;
  let pages = 0;

  do {
    const url = new URL(`${API}/playlistItems`);
    url.searchParams.set('part', 'snippet,contentDetails');
    url.searchParams.set('playlistId', playlistId);
    url.searchParams.set('maxResults', String(PAGE_SIZE));
    if (pageToken) url.searchParams.set('pageToken', pageToken);

    const { status, body, message } = await call<ListResponse<PlaylistItemResource>>(
      url,
      credential,
    );

    if (status === 403) throw notVisible(credential, message);
    if (status === 404) {
      throw providerNotFound('That YouTube playlist does not exist, or has been deleted.');
    }
    if (status < 200 || status >= 300) {
      throw unavailable(
        `YouTube could not return that playlist's videos (HTTP ${status}). ${message}`.trim(),
      );
    }

    for (const item of body?.items ?? []) {
      position += 1;

      const videoId = item.contentDetails?.videoId ?? item.snippet?.resourceId?.videoId ?? '';
      const title = item.snippet?.title?.trim() ?? '';
      const channel = item.snippet?.videoOwnerChannelTitle?.trim() ?? '';

      if (!videoId) {
        skipped.push({ position, reason: 'no_id' });
        continue;
      }

      // A video that has been made private or deleted since it was added. The
      // API still lists the entry, with a placeholder title and no owning
      // channel — see HIDDEN_TITLES. Importing it would put a row called
      // "Private video" in the user's library.
      if (HIDDEN_TITLES.has(title) && !channel) {
        skipped.push({ position, reason: 'private_video' });
        continue;
      }

      entries.push({
        videoId,
        title,
        channel,
        artworkUrl: bestThumbnail(item.snippet?.thumbnails),
      });

      if (entries.length >= MAX_TRACKS) {
        truncated = true;
        break;
      }
    }

    if (truncated) break;
    pageToken = body?.nextPageToken;

    pages += 1;
    if (pages > Math.ceil(MAX_TRACKS / PAGE_SIZE) + 2) {
      log.warn(`YouTube paging for ${playlistId} did not terminate; stopping`, 'music');
      truncated = true;
      break;
    }
  } while (pageToken);

  return { entries, skipped, truncated };
}

/**
 * Fills in durations, in batches of fifty.
 *
 * `playlistItems.list` does not carry a duration — it is on the video resource,
 * which is a second endpoint. Worth the extra calls (one per fifty songs)
 * because a library where every imported YouTube track shows `0:00` looks
 * broken, and the player needs a length to draw a progress bar against.
 *
 * **Failure here is not fatal.** A quota error or a partial response costs the
 * durations and nothing else, so it degrades to zero rather than losing the
 * import. That is a deliberate asymmetry: the track list is the deliverable, the
 * durations are an enrichment.
 */
async function resolveDurations(
  entries: PendingTrack[],
  credential: ProviderCredential | null,
): Promise<ProviderTrack[]> {
  const durations = new Map<string, number>();

  for (let index = 0; index < entries.length; index += DETAIL_BATCH) {
    const batch = entries.slice(index, index + DETAIL_BATCH);
    const url = new URL(`${API}/videos`);
    url.searchParams.set('part', 'contentDetails');
    url.searchParams.set('id', batch.map((entry) => entry.videoId).join(','));

    try {
      const { status, body } = await call<ListResponse<VideoResource>>(url, credential);
      if (status < 200 || status >= 300) {
        log.warn(`YouTube durations unavailable (HTTP ${status}); importing without`, 'music');
        break;
      }
      for (const video of body?.items ?? []) {
        if (!video.id) continue;
        durations.set(video.id, parseIsoDuration(video.contentDetails?.duration ?? ''));
      }
    } catch (error) {
      // Includes the rate-limit throw from `call`. Losing durations is a much
      // better outcome than losing the import.
      log.warn('Could not resolve YouTube durations; importing without', 'music', error);
      break;
    }
  }

  return entries.map((entry) => ({
    providerTrackId: entry.videoId,
    // A YouTube title is "Artist - Song (Official Video)", not a song title.
    // Split so the library shows something a person recognises, but keep the
    // channel as the artist when the title carries no separator.
    ...splitTitle(entry.title, entry.channel),
    album: '',
    durationMs: durations.get(entry.videoId) ?? 0,
    artworkUrl: entry.artworkUrl,
    explicit: false,
    externalUrl: `https://www.youtube.com/watch?v=${entry.videoId}`,
  }));
}

// ---------------------------------------------------------------------------
// Mapping
// ---------------------------------------------------------------------------

/**
 * "Artist - Title (Official Video)" → `{ title, artists }`.
 *
 * A best effort at a genuinely ambiguous problem, and it is worth being clear
 * that it is one: YouTube has no artist field, only a channel and a free-text
 * title, so anything here is a heuristic. Two rules, both conservative:
 *
 *  * Split on the first ` - ` only, and only when both halves are non-empty.
 *    Titles like "Song - Part 2 - Live" then keep everything after the first
 *    separator as the title rather than losing it.
 *  * Strip the bracketed noise YouTube titles carry — "(Official Video)",
 *    "[Lyrics]", "(4K Remaster)" — because it is not part of the song's name
 *    and it defeats matching against the same song imported from Spotify.
 *
 * When there is no separator the channel becomes the artist, which is right for
 * a topic channel ("Artist - Topic") and merely harmless otherwise.
 */
function splitTitle(rawTitle: string, channel: string): { title: string; artists: string[] } {
  const cleaned = rawTitle
    .replace(/\s*[([][^)\]]*(?:official|video|audio|lyric|lyrics|hd|4k|mv|m\/v|visualizer|remaster(?:ed)?)[^)\]]*[)\]]/gi, '')
    .trim();

  // "Artist - Topic" is YouTube's auto-generated channel for a licensed
  // release, and the suffix is not part of the artist's name.
  const channelArtist = channel.replace(/\s*-\s*Topic$/i, '').trim();

  const separator = cleaned.indexOf(' - ');
  if (separator > 0) {
    const artist = cleaned.slice(0, separator).trim();
    const title = cleaned.slice(separator + 3).trim();
    if (artist && title) return { title, artists: [artist] };
  }

  return {
    title: cleaned || rawTitle.trim() || 'Unknown track',
    artists: channelArtist ? [channelArtist] : [],
  };
}

/** ISO 8601 `PT4M13S` → milliseconds. */
function parseIsoDuration(value: string): number {
  const match = /^P(?:(\d+)D)?T?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$/.exec(value);
  if (!match) return 0;
  const [, days, hours, minutes, seconds] = match;
  return Math.round(
    ((Number(days ?? 0) * 24 + Number(hours ?? 0)) * 3600 +
      Number(minutes ?? 0) * 60 +
      Number(seconds ?? 0)) *
      1000,
  );
}

/**
 * The largest thumbnail YouTube offers.
 *
 * The keys are named sizes (`default`, `medium`, `high`, `standard`, `maxres`)
 * rather than an ordered array, and not every video has every size — a
 * user-uploaded video often stops at `high`. Picking by width rather than by a
 * preferred-name list is what makes this return the best *available* one
 * instead of an empty string.
 */
function bestThumbnail(thumbnails: Thumbnails | undefined): string {
  if (!thumbnails) return '';
  let best: Thumbnail | undefined;
  for (const candidate of Object.values(thumbnails)) {
    if (!candidate?.url) continue;
    if (!best || (candidate.width ?? 0) > (best.width ?? 0)) best = candidate;
  }
  return best?.url ?? '';
}
