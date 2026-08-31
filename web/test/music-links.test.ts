import { describe, expect, it } from 'vitest';

import { parsePlaylistLink } from '@/server/services/music/links';
import { ApiError } from '@/server/utils/errors';

/**
 * Link parsing.
 *
 * The route derives `(provider, playlistId)` from the pasted link and never
 * takes it from the request body, so everything downstream — which connection is
 * looked up, whose ownership is checked, which document id is written — depends
 * on these being right.
 */

const refusal = (input: string): ApiError => {
  try {
    parsePlaylistLink(input);
  } catch (error) {
    return error as ApiError;
  }
  throw new Error(`expected "${input}" to be refused`);
};

describe('Spotify links', () => {
  const id = '22WMPdyCLdKfeRraLxZbMw';

  it.each([
    ['a share link', `https://open.spotify.com/playlist/${id}`],
    ['a share link with tracking', `https://open.spotify.com/playlist/${id}?si=abc123&pt=x`],
    ['a localised link', `https://open.spotify.com/intl-de/playlist/${id}`],
    ['no scheme', `open.spotify.com/playlist/${id}`],
    ['a desktop URI', `spotify:playlist:${id}`],
    ['a bare id', id],
    ['surrounding whitespace', `  https://open.spotify.com/playlist/${id}  `],
  ])('reads %s', (_label, input) => {
    const parsed = parsePlaylistLink(input);
    expect(parsed.provider).toBe('spotify');
    expect(parsed.playlistId).toBe(id);
    expect(parsed.externalUrl).toBe(`https://open.spotify.com/playlist/${id}`);
  });

  it('does not mistake a trailing tracking segment for the id', () => {
    // The failure this guards against: taking the *last* path segment rather
    // than the one after "playlist" picks up a 22-character tracking value and
    // imports a playlist that does not exist.
    const parsed = parsePlaylistLink(`https://open.spotify.com/playlist/${id}/aBcDeFgHiJkLmNoPqRsTuV`);
    expect(parsed.playlistId).toBe(id);
  });

  it('refuses a Spotify link that is not to a playlist', () => {
    const error = refusal('https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC');
    expect(error.code).toBe('provider_unsupported_link');
    expect(error.message).toContain('not to a playlist');
  });

  it('refuses an id of the wrong length', () => {
    expect(refusal('https://open.spotify.com/playlist/tooshort').code).toBe(
      'provider_unsupported_link',
    );
  });
});

describe('YouTube links', () => {
  const id = 'PLFgquLnL59alW3xmYiWRaoz0oM3H17Lth';

  it.each([
    ['a playlist page', `https://www.youtube.com/playlist?list=${id}`],
    ['YouTube Music', `https://music.youtube.com/playlist?list=${id}`],
    ['mobile', `https://m.youtube.com/playlist?list=${id}`],
    ['a watch link carrying a list', `https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=${id}`],
    ['no scheme', `music.youtube.com/playlist?list=${id}`],
  ])('reads %s', (_label, input) => {
    const parsed = parsePlaylistLink(input);
    expect(parsed.provider).toBe('youtube');
    expect(parsed.playlistId).toBe(id);
  });

  it('treats a YouTube Music link as the same playlist as the YouTube one', () => {
    // The claim the whole YouTube provider rests on: YouTube Music has no API
    // of its own, and this is only importable because the two are one playlist.
    const music = parsePlaylistLink(`https://music.youtube.com/playlist?list=${id}`);
    const video = parsePlaylistLink(`https://www.youtube.com/playlist?list=${id}`);
    expect(music.playlistId).toBe(video.playlistId);
    expect(music.externalUrl).toBe(video.externalUrl);
  });

  it('reads an album (OLAK5uy_) link', () => {
    const album = 'OLAK5uy_kZ8w1nq5cGvVJ2Vf3nQnLBLrCEbAr1Zpk';
    expect(parsePlaylistLink(`https://music.youtube.com/playlist?list=${album}`).playlistId).toBe(
      album,
    );
  });

  it.each([
    ['LL', 'Liked videos'],
    ['WL', 'Watch Later'],
  ])('refuses %s with an explanation rather than importing nothing', (listId) => {
    // These resolve to a real playlist id and then return an empty page from
    // the API, which would look like a successful import of an empty playlist.
    const error = refusal(`https://www.youtube.com/playlist?list=${listId}`);
    expect(error.code).toBe('provider_unsupported_link');
    expect(error.message).toMatch(/does not let any app read/);
  });

  it('refuses a YouTube link with no list parameter', () => {
    const error = refusal('https://www.youtube.com/watch?v=dQw4w9WgXcQ');
    expect(error.message).toContain('list=');
  });
});

describe('anything else', () => {
  it('names the provider it does not support', () => {
    const error = refusal('https://soundcloud.com/someone/sets/mix');
    expect(error.code).toBe('provider_unsupported_link');
    expect(error.message).toContain('soundcloud.com');
  });

  it('refuses an empty string', () => {
    expect(refusal('   ').code).toBe('provider_unsupported_link');
  });

  it('refuses something that is not a URL at all', () => {
    expect(refusal('my favourite songs').code).toBe('provider_unsupported_link');
  });
});
