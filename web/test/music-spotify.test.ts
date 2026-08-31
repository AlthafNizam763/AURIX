import { afterEach, describe, expect, it, vi } from 'vitest';

import { spotifyFetcher } from '@/server/services/music/spotify';
import type { ProviderCredential } from '@/server/services/music/types';
import { ApiError } from '@/server/utils/errors';

/**
 * The Spotify fetcher — the file that fixes the reported bug.
 *
 * These tests pin the two things that were actually wrong, and they are written
 * so that reintroducing either one fails here rather than in production:
 *
 *  1. the items endpoint is `/playlists/{id}/items`, and the removed `/tracks`
 *     is never called;
 *  2. a 403 from the items endpoint is reported as an ownership refusal naming
 *     the account, not as "contents unavailable".
 *
 * `fetch` is stubbed rather than recorded, because the interesting cases —
 * a 403 on page one, a token dying mid-page-three — are ones a live account
 * cannot be made to produce on demand.
 */

const CREDENTIAL: ProviderCredential = {
  accessToken: 'test-access-token',
  scopes: ['playlist-read-private', 'playlist-read-collaborative', 'user-read-private'],
  accountId: 'althaf',
};

const PLAYLIST_ID = '22WMPdyCLdKfeRraLxZbMw';

interface StubResponse {
  status: number;
  body: unknown;
  headers?: Record<string, string>;
}

/** Serves canned responses and records every URL asked for. */
function stubFetch(routes: (url: string) => StubResponse) {
  const calls: string[] = [];
  vi.stubGlobal('fetch', async (input: URL | string) => {
    const url = String(input);
    calls.push(url);
    const { status, body, headers } = routes(url);
    return new Response(body === null ? null : JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json', ...headers },
    });
  });
  return calls;
}

const metadata = (over: Record<string, unknown> = {}) => ({
  id: PLAYLIST_ID,
  name: 'Late night',
  description: 'Songs for <b>driving</b> &amp; thinking',
  images: [
    { url: 'https://img/small.jpg', width: 64 },
    { url: 'https://img/large.jpg', width: 640 },
  ],
  owner: { id: 'althaf', display_name: 'Althaf' },
  external_urls: { spotify: `https://open.spotify.com/playlist/${PLAYLIST_ID}` },
  items: { total: 3 },
  ...over,
});

const track = (id: string, name: string) => ({
  id,
  name,
  type: 'track',
  duration_ms: 213_000,
  explicit: false,
  preview_url: null,
  artists: [{ id: 'a1', name: 'Artist One' }, { id: 'a2', name: 'Artist Two' }],
  album: { name: 'An Album', images: [{ url: 'https://img/art.jpg', width: 640 }] },
  external_urls: { spotify: `https://open.spotify.com/track/${id}` },
});

afterEach(() => vi.unstubAllGlobals());

const failure = async (): Promise<ApiError> => {
  try {
    await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
  } catch (error) {
    return error as ApiError;
  }
  throw new Error('expected a failure');
};

describe('the endpoint that is actually called', () => {
  it('reads items from /items and never touches the removed /tracks', async () => {
    const calls = stubFetch((url) => {
      if (url.includes('/items')) {
        return { status: 200, body: { items: [{ item: track('t1', 'One') }], next: null, total: 1 } };
      }
      return { status: 200, body: metadata({ items: { total: 1 } }) };
    });

    await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);

    expect(calls.some((url) => url.includes(`/playlists/${PLAYLIST_ID}/items`))).toBe(true);
    // `/playlists/{id}/tracks` was removed in February 2026 and answers 403 to
    // every caller since 9 March 2026. Calling it can only add a failed request
    // and the "refused both" log line the bug report quoted.
    expect(calls.some((url) => url.includes('/tracks'))).toBe(false);
  });

  it('does not ask the metadata endpoint to inline the items it is about to page', async () => {
    const calls = stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [], next: null, total: 0 } }
        : { status: 200, body: metadata({ items: { total: 0 } }) },
    );

    await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);

    const detail = calls.find((url) => !url.includes('/items?') && url.includes('/playlists/'))!;
    expect(decodeURIComponent(detail)).toContain('fields=');
  });
});

describe('the item/track field rename', () => {
  it('reads the current `item` field', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [{ item: track('t1', 'Current') }], next: null } }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks).toHaveLength(1);
    expect(result.tracks[0]!.title).toBe('Current');
  });

  it('still reads the deprecated `track` field', async () => {
    // Spotify marks `track` deprecated but keeps sending it. Reading only
    // `item` would break against a deployment still serving the old shape.
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [{ track: track('t1', 'Legacy') }], next: null } }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks[0]!.title).toBe('Legacy');
  });

  it('prefers `item` when a response carries both', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? {
            status: 200,
            body: {
              items: [{ item: track('t1', 'Current'), track: track('t1', 'Legacy') }],
              next: null,
            },
          }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks[0]!.title).toBe('Current');
  });
});

describe('pagination', () => {
  it('follows `next` to the end and keeps the source order', async () => {
    const page = (ids: string[], next: string | null) => ({
      items: ids.map((id) => ({ item: track(id, `Track ${id}`) })),
      next,
      total: 5,
    });

    stubFetch((url) => {
      if (!url.includes('/items')) return { status: 200, body: metadata({ items: { total: 5 } }) };
      if (url.includes('page=2')) return { status: 200, body: page(['t3', 't4'], `https://api.spotify.com/v1/playlists/${PLAYLIST_ID}/items?offset=100&page=3`) };
      if (url.includes('page=3')) return { status: 200, body: page(['t5'], null) };
      return { status: 200, body: page(['t1', 't2'], `https://api.spotify.com/v1/playlists/${PLAYLIST_ID}/items?offset=50&page=2`) };
    });

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);

    expect(result.tracks.map((t) => t.providerTrackId)).toEqual(['t1', 't2', 't3', 't4', 't5']);
    expect(result.truncated).toBe(false);
  });

  it('stops when `next` is null even on a full page', async () => {
    // The old client stopped on a *short page* as well, which drops the tail of
    // a playlist whose last page happens to be exactly 50 long.
    const full = Array.from({ length: 50 }, (_, i) => ({ item: track(`t${i}`, `Track ${i}`) }));
    let served = 0;

    stubFetch((url) => {
      if (!url.includes('/items')) return { status: 200, body: metadata({ items: { total: 50 } }) };
      served += 1;
      return { status: 200, body: { items: full, next: null, total: 50 } };
    });

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks).toHaveLength(50);
    expect(served).toBe(1);
  });

  it('does not report an empty playlist as a failure', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [], next: null, total: 0 } }
        : { status: 200, body: metadata({ items: { total: 0 } }) },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks).toHaveLength(0);
    expect(result.playlist.name).toBe('Late night');
  });
});

describe('entries that cannot be imported', () => {
  it('records why each was skipped instead of dropping it silently', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? {
            status: 200,
            body: {
              items: [
                { item: track('t1', 'Fine') },
                { item: null },
                { item: { ...track('t2', 'Local'), id: null }, is_local: true },
                { item: { ...track('t3', 'Episode'), type: 'episode' } },
                { item: { ...track('t4', 'No id'), id: null } },
              ],
              next: null,
            },
          }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);

    expect(result.tracks.map((t) => t.providerTrackId)).toEqual(['t1']);
    expect(result.skipped.map((s) => s.reason)).toEqual([
      'deleted',
      'local_file',
      'not_a_track',
      'no_id',
    ]);
    // Positions are the source's, so "song 3 of 5 was removed from Spotify" is
    // something the UI can actually say.
    expect(result.skipped.map((s) => s.position)).toEqual([2, 3, 4, 5]);
  });
});

describe('refusals', () => {
  it('reports a 403 on items as an ownership problem, naming the owner and the account', async () => {
    // The exact reported failure: metadata 200, items 403.
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 403, body: { error: { status: 403, message: 'Forbidden' } } }
        : { status: 200, body: metadata({ owner: { id: 'someone', display_name: 'Someone Else' } }) },
    );

    const error = await failure();

    expect(error.status).toBe(403);
    expect(error.code).toBe('provider_forbidden');
    // Never the old wording, which named neither cause nor remedy.
    expect(error.message).not.toMatch(/contents unavailable/i);
    expect(error.message).toContain('Someone Else');
    expect(error.message).toContain('althaf');
    expect(error.message).toMatch(/owns or collaborates on/);
  });

  it('explains an editorial playlist rather than blaming the account', async () => {
    const editorial = '37i9dQZF1DXcBWIGoYBM5M';
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 403, body: { error: { message: 'Forbidden' } } }
        : { status: 200, body: metadata({ id: editorial, owner: { id: 'spotify', display_name: 'Spotify' } }) },
    );

    let error: ApiError;
    try {
      await spotifyFetcher.fetch(editorial, CREDENTIAL);
      throw new Error('expected a failure');
    } catch (thrown) {
      error = thrown as ApiError;
    }

    expect(error.code).toBe('provider_forbidden');
    expect(error.message).toMatch(/editorial/i);
  });

  it('asks for a reconnect on 401 rather than reporting an empty playlist', async () => {
    stubFetch(() => ({ status: 401, body: { error: { message: 'The access token expired' } } }));
    const error = await failure();
    expect(error.code).toBe('provider_reconnect_required');
  });

  it('honours Retry-After on 429', async () => {
    stubFetch(() => ({ status: 429, body: null, headers: { 'retry-after': '17' } }));
    const error = await failure();
    expect(error.code).toBe('provider_rate_limited');
    expect(error.headers?.['Retry-After']).toBe('17');
  });

  it('separates a deleted playlist from a restricted one', async () => {
    stubFetch(() => ({ status: 404, body: { error: { message: 'Not found.' } } }));
    const error = await failure();
    expect(error.code).toBe('provider_not_found');
    expect(error.message).toMatch(/does not exist/);
  });
});

describe('metadata mapping', () => {
  it('flattens the HTML Spotify allows in a description', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [], next: null } }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.playlist.description).toBe('Songs for driving & thinking');
  });

  it('takes the largest cover, not the first listed', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [], next: null } }
        : {
            status: 200,
            body: metadata({
              images: [
                { url: 'https://img/small.jpg', width: 64 },
                { url: 'https://img/large.jpg', width: 640 },
              ],
            }),
          },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.playlist.coverUrl).toBe('https://img/large.jpg');
  });

  it('joins every credited artist', async () => {
    stubFetch((url) =>
      url.includes('/items')
        ? { status: 200, body: { items: [{ item: track('t1', 'One') }], next: null } }
        : { status: 200, body: metadata() },
    );

    const result = await spotifyFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(result.tracks[0]!.artists).toEqual(['Artist One', 'Artist Two']);
  });
});
