import { afterEach, describe, expect, it, vi } from 'vitest';

import { youtubeFetcher } from '@/server/services/music/youtube';
import type { ProviderCredential } from '@/server/services/music/types';
import { ApiError } from '@/server/utils/errors';

// `vi.hoisted` runs before the imports above, which is the only moment early
// enough to matter: `config/env.ts` reads `process.env` once, when the module is
// first evaluated, so setting the key in `beforeEach` would be too late and
// every "public playlist" test would see an unconfigured deployment.
vi.hoisted(() => {
  process.env.YOUTUBE_API_KEY = 'test-key';
});

/**
 * The YouTube fetcher.
 *
 * The interesting behaviour is not the happy path — it is the four cases where
 * the Data API answers something that *looks* like success and is not:
 *
 *  * a 200 with an empty `items` array, which is how it says "no such playlist,
 *    or you may not see it";
 *  * an ordinary-looking entry whose video has since been made private;
 *  * a 403 that means "quota exhausted" rather than "forbidden";
 *  * a missing duration, because durations are on a different endpoint.
 *
 * Every one of those, handled naively, produces a silently empty or silently
 * wrong import — which is the failure mode §5 and §10 exist to rule out.
 */

const PLAYLIST_ID = 'PLFgquLnL59alW3xmYiWRaoz0oM3H17Lth';

const CREDENTIAL: ProviderCredential = {
  accessToken: 'test-access-token',
  scopes: ['https://www.googleapis.com/auth/youtube.readonly'],
  accountId: 'UCchannel',
};

interface StubResponse {
  status: number;
  body: unknown;
}

function stubFetch(routes: (url: string) => StubResponse) {
  const calls: string[] = [];
  vi.stubGlobal('fetch', async (input: URL | string) => {
    const url = String(input);
    calls.push(url);
    const { status, body } = routes(url);
    return new Response(body === null ? null : JSON.stringify(body), {
      status,
      headers: { 'content-type': 'application/json' },
    });
  });
  return calls;
}

const playlistResource = (over: Record<string, unknown> = {}) => ({
  items: [
    {
      id: PLAYLIST_ID,
      snippet: {
        title: 'Night drive',
        description: 'a description',
        channelTitle: 'Althaf',
        thumbnails: {
          default: { url: 'https://i.ytimg.com/small.jpg', width: 120 },
          maxres: { url: 'https://i.ytimg.com/max.jpg', width: 1280 },
        },
      },
      contentDetails: { itemCount: 2 },
      ...over,
    },
  ],
});

const item = (videoId: string, title: string, channel = 'Some Artist - Topic') => ({
  snippet: {
    title,
    videoOwnerChannelTitle: channel,
    thumbnails: { high: { url: `https://i.ytimg.com/${videoId}.jpg`, width: 480 } },
    resourceId: { kind: 'youtube#video', videoId },
  },
  contentDetails: { videoId },
});

afterEach(() => vi.unstubAllGlobals());

const failureFor = async (credential: ProviderCredential | null): Promise<ApiError> => {
  try {
    await youtubeFetcher.fetch(PLAYLIST_ID, credential);
  } catch (error) {
    return error as ApiError;
  }
  throw new Error('expected a failure');
};

function route(url: string): StubResponse {
  if (url.includes('/playlists')) return { status: 200, body: playlistResource() };
  if (url.includes('/playlistItems')) {
    return {
      status: 200,
      body: { items: [item('v1', 'Artist One - First Song (Official Video)'), item('v2', 'Second')] },
    };
  }
  if (url.includes('/videos')) {
    return {
      status: 200,
      body: {
        items: [
          { id: 'v1', contentDetails: { duration: 'PT3M33S' } },
          { id: 'v2', contentDetails: { duration: 'PT4M13S' } },
        ],
      },
    };
  }
  return { status: 404, body: null };
}

describe('a public playlist', () => {
  it('imports with an API key and no user connection', async () => {
    // The requirement in one test: authorization is asked for only when it is
    // actually needed, and a public YouTube playlist does not need it.
    const calls = stubFetch(route);

    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);

    expect(result.tracks).toHaveLength(2);
    expect(calls.every((url) => url.includes('key=test-key'))).toBe(true);
  });

  it('uses the bearer token and never the key when connected', async () => {
    const calls = stubFetch(route);
    await youtubeFetcher.fetch(PLAYLIST_ID, CREDENTIAL);
    expect(calls.some((url) => url.includes('key='))).toBe(false);
  });
});

describe('titles and durations', () => {
  it('splits "Artist - Title" and strips the bracketed noise', async () => {
    stubFetch(route);
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);

    expect(result.tracks[0]!.title).toBe('First Song');
    expect(result.tracks[0]!.artists).toEqual(['Artist One']);
  });

  it('falls back to the channel, minus the "- Topic" suffix', async () => {
    stubFetch(route);
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);

    // "Second" carries no separator, so the channel is the best guess available.
    expect(result.tracks[1]!.title).toBe('Second');
    expect(result.tracks[1]!.artists).toEqual(['Some Artist']);
  });

  it('resolves durations from the videos endpoint', async () => {
    stubFetch(route);
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);

    expect(result.tracks[0]!.durationMs).toBe(213_000);
    expect(result.tracks[1]!.durationMs).toBe(253_000);
  });

  it('imports without durations rather than failing when that endpoint refuses', async () => {
    // Losing the durations is a much better outcome than losing the import.
    stubFetch((url) => (url.includes('/videos') ? { status: 500, body: null } : route(url)));

    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);
    expect(result.tracks).toHaveLength(2);
    expect(result.tracks[0]!.durationMs).toBe(0);
  });
});

describe('pagination', () => {
  it('follows nextPageToken to the end', async () => {
    stubFetch((url) => {
      if (url.includes('/playlists')) return { status: 200, body: playlistResource() };
      if (url.includes('/playlistItems')) {
        return url.includes('pageToken=p2')
          ? { status: 200, body: { items: [item('v3', 'Third')] } }
          : { status: 200, body: { items: [item('v1', 'First')], nextPageToken: 'p2' } };
      }
      return { status: 200, body: { items: [] } };
    });

    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);
    expect(result.tracks.map((t) => t.providerTrackId)).toEqual(['v1', 'v3']);
  });
});

describe('entries that cannot be imported', () => {
  it('skips a video that has been made private, rather than importing "Private video"', async () => {
    stubFetch((url) => {
      if (url.includes('/playlists')) return { status: 200, body: playlistResource() };
      if (url.includes('/playlistItems')) {
        return {
          status: 200,
          body: {
            items: [
              item('v1', 'Artist - Real Song'),
              // What the API sends for a video made private after it was added:
              // a placeholder title and no owning channel.
              { snippet: { title: 'Private video', thumbnails: {}, resourceId: { videoId: 'v2' } }, contentDetails: { videoId: 'v2' } },
              { snippet: { title: 'Deleted video', thumbnails: {}, resourceId: { videoId: 'v3' } }, contentDetails: { videoId: 'v3' } },
            ],
          },
        };
      }
      return { status: 200, body: { items: [] } };
    });

    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);

    expect(result.tracks.map((t) => t.providerTrackId)).toEqual(['v1']);
    expect(result.skipped).toEqual([
      { position: 2, reason: 'private_video' },
      { position: 3, reason: 'private_video' },
    ]);
  });

  it('does not skip a real song that happens to be called "Private video"', async () => {
    stubFetch((url) => {
      if (url.includes('/playlists')) return { status: 200, body: playlistResource() };
      if (url.includes('/playlistItems')) {
        return { status: 200, body: { items: [item('v1', 'Private video', 'A Real Channel')] } };
      }
      return { status: 200, body: { items: [] } };
    });

    // The owning channel is present, so this is a real video with an unlucky
    // title — matching on the title alone would have dropped it.
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);
    expect(result.tracks).toHaveLength(1);
  });
});

describe('refusals', () => {
  it('asks an unconnected caller to connect when the playlist is not visible', async () => {
    // A 200 with an empty `items` array is how the API says "no such playlist,
    // or you may not see it". For an unconnected caller, connecting may fix it.
    stubFetch(() => ({ status: 200, body: { items: [] } }));

    const error = await failureFor(null);
    expect(error.code).toBe('provider_auth_required');
    expect(error.status).toBe(428);
  });

  it('tells a connected caller the playlist is not theirs', async () => {
    stubFetch(() => ({ status: 200, body: { items: [] } }));

    const error = await failureFor(CREDENTIAL);
    // Connecting again cannot help, so it must not be what the user is told.
    expect(error.code).toBe('provider_not_found');
    expect(error.code).not.toBe('provider_auth_required');
  });

  it('explains an auto-generated mix instead of reporting a missing playlist', async () => {
    stubFetch(() => ({ status: 200, body: { items: [] } }));

    let error: ApiError;
    try {
      await youtubeFetcher.fetch('RDAMVMdQw4w9WgXcQ', CREDENTIAL);
      throw new Error('expected a failure');
    } catch (thrown) {
      error = thrown as ApiError;
    }

    expect(error.message).toMatch(/automatically generated mixes/);
  });

  it('reports an exhausted quota as rate limiting, not as a permission problem', async () => {
    // Google returns 403 for quota exhaustion. Reporting it as "forbidden"
    // would send the user to reconnect an account that is working fine.
    stubFetch(() => ({
      status: 403,
      body: { error: { message: 'Quota exceeded', errors: [{ reason: 'quotaExceeded' }] } },
    }));

    const error = await failureFor(CREDENTIAL);
    expect(error.code).toBe('provider_rate_limited');
  });

  it('reports a genuine 403 as a private playlist', async () => {
    stubFetch(() => ({
      status: 403,
      body: { error: { message: 'The caller does not have permission', errors: [{ reason: 'forbidden' }] } },
    }));

    const error = await failureFor(CREDENTIAL);
    expect(error.code).toBe('provider_forbidden');
    expect(error.message).toMatch(/private/);
  });
});

describe('metadata', () => {
  it('takes the largest thumbnail available', async () => {
    stubFetch(route);
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);
    expect(result.playlist.coverUrl).toBe('https://i.ytimg.com/max.jpg');
  });

  it('carries the channel through as the owner', async () => {
    stubFetch(route);
    const result = await youtubeFetcher.fetch(PLAYLIST_ID, null);
    expect(result.playlist.ownerName).toBe('Althaf');
    expect(result.playlist.name).toBe('Night drive');
  });
});
