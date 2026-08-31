import type { MusicProviderId } from '../../config/env';
import { unsupportedLink } from '../../utils/errors';

/**
 * Turning a pasted link into `(provider, playlistId)`.
 *
 * ## Why this is on the server
 *
 * The Dart side has its own parser (`playlist_url.dart`) and keeps it, because
 * validating as the user types is a client job. This one exists because the
 * *import* must not trust what the client says the id is: a route that accepted
 * `{ provider, playlistId }` from the body would let a caller name any provider
 * for any id, and the whole authorization decision downstream keys off exactly
 * that pair. The link is the input; the pair is derived here.
 *
 * ## What counts as a link
 *
 * Deliberately generous about *form* and strict about *identity*. Users paste
 * share links with tracking parameters, `spotify:` URIs copied from the desktop
 * app, links with a locale segment, and sometimes a bare id. All of those name
 * the same playlist unambiguously, so all of them are accepted. What is not
 * accepted is anything whose provider or id cannot be determined — those get a
 * message naming what AURIX can take, rather than a generic parse failure.
 */

export interface ParsedPlaylistLink {
  provider: MusicProviderId;
  playlistId: string;
  /** A canonical link back to the playlist, stored as `sourceUrl`. */
  externalUrl: string;
}

/** Spotify ids are base62, always 22 characters. */
const SPOTIFY_ID = /^[A-Za-z0-9]{22}$/;

/**
 * YouTube playlist ids.
 *
 * `PL…` user playlists, `OLAK5uy_…` auto-generated release playlists (which is
 * what a YouTube Music *album* link is), `RD…`/`RDCLAK5uy_…` radio mixes, `FL…`
 * favourites, `UU…`/`UULF…` channel-uploads playlists, and `LL`/`WL` for the
 * signed-in user's Liked/Watch Later.
 *
 * Kept as a character-class test rather than an enumeration of prefixes,
 * because the prefix set is not documented and has grown; the length and
 * alphabet have not.
 */
const YOUTUBE_ID = /^[A-Za-z0-9_-]{2,64}$/;

/**
 * Ids that are real playlist ids but that the API will never serve.
 *
 * `LL` (Liked videos) and `WL` (Watch Later) are private to the account in a
 * way that OAuth does not lift: the Data API returns an empty page for them
 * even with `youtube.readonly` granted, which would make an import look like it
 * succeeded and produced an empty playlist. Refused up front, with the reason.
 */
const YOUTUBE_UNSERVABLE = new Set(['LL', 'WL']);

const SPOTIFY_HOSTS = new Set(['open.spotify.com', 'play.spotify.com', 'spotify.com']);
const YOUTUBE_HOSTS = new Set([
  'youtube.com',
  'm.youtube.com',
  'music.youtube.com',
  'youtu.be',
]);

const stripWww = (host: string): string => host.replace(/^www\./, '').toLowerCase();

export const spotifyPlaylistUrl = (id: string): string =>
  `https://open.spotify.com/playlist/${id}`;

export const youtubePlaylistUrl = (id: string): string =>
  `https://www.youtube.com/playlist?list=${id}`;

/**
 * Parses a pasted link, or throws `provider_unsupported_link`.
 *
 * Never returns a partially-understood result: if the provider is known but the
 * id is not usable, that is still a refusal, because an import that proceeded
 * on a guessed id would fail later with a message about the wrong thing.
 */
export function parsePlaylistLink(raw: string): ParsedPlaylistLink {
  const input = raw.trim();
  if (!input) throw unsupportedLink('Paste a Spotify or YouTube playlist link.');

  // `spotify:playlist:37i9…`, as copied from the desktop app's share menu.
  const uriMatch = /^spotify:playlist:([A-Za-z0-9]+)$/.exec(input);
  if (uriMatch) return spotify(uriMatch[1]!);

  // A bare id, which is what someone pastes when they copied from a URL bar
  // that had already eaten the rest. Only Spotify's shape is unambiguous enough
  // to accept bare — a bare YouTube id overlaps with far too much.
  if (SPOTIFY_ID.test(input)) return spotify(input);

  const url = toUrl(input);
  if (!url) {
    throw unsupportedLink(
      'That does not look like a playlist link. Paste a Spotify or YouTube ' +
        'Music playlist URL.',
    );
  }

  const host = stripWww(url.hostname);

  if (SPOTIFY_HOSTS.has(host)) {
    // `/playlist/{id}` and the localised `/intl-de/playlist/{id}`. Taking the
    // segment *after* "playlist" rather than the last segment matters: share
    // links sometimes carry a trailing segment, and the last one is then a
    // tracking value that parses as an id-shaped string.
    const segments = url.pathname.split('/').filter(Boolean);
    const at = segments.indexOf('playlist');
    const id = at >= 0 ? segments[at + 1] : undefined;
    if (!id) {
      throw unsupportedLink(
        'That is a Spotify link, but not to a playlist. Open the playlist in ' +
          'Spotify and use Share → Copy link to playlist.',
      );
    }
    return spotify(id);
  }

  if (YOUTUBE_HOSTS.has(host)) {
    // `list=` is where the playlist id lives on every YouTube surface —
    // /playlist, /watch, and music.youtube.com alike. A YouTube Music playlist
    // *is* a YouTube playlist with the same id, which is what makes importing
    // one through the Data API possible at all.
    const id = url.searchParams.get('list');
    if (!id) {
      throw unsupportedLink(
        'That YouTube link does not name a playlist. Open the playlist and ' +
          'copy the link from its own page — it will contain "list=".',
      );
    }
    return youtube(id);
  }

  throw unsupportedLink(
    'AURIX can import from Spotify and YouTube Music. That link is from ' +
      `${host || 'somewhere else'}.`,
  );
}

function toUrl(input: string): URL | null {
  try {
    // Users paste "open.spotify.com/playlist/…" without a scheme often enough
    // to be worth handling rather than refusing.
    return new URL(/^https?:\/\//i.test(input) ? input : `https://${input}`);
  } catch {
    return null;
  }
}

function spotify(rawId: string): ParsedPlaylistLink {
  const id = rawId.split('?')[0]!.trim();
  if (!SPOTIFY_ID.test(id)) {
    throw unsupportedLink(
      'That Spotify playlist id does not look right. A Spotify link ends in ' +
        '22 letters and digits.',
    );
  }
  return { provider: 'spotify', playlistId: id, externalUrl: spotifyPlaylistUrl(id) };
}

function youtube(rawId: string): ParsedPlaylistLink {
  const id = rawId.trim();

  if (YOUTUBE_UNSERVABLE.has(id)) {
    throw unsupportedLink(
      id === 'LL'
        ? 'YouTube does not let any app read your Liked videos playlist, even ' +
            'with your permission. Add the videos to an ordinary playlist and ' +
            'import that instead.'
        : 'YouTube does not let any app read Watch Later. Add the videos to an ' +
            'ordinary playlist and import that instead.',
    );
  }

  if (!YOUTUBE_ID.test(id)) {
    throw unsupportedLink('That YouTube playlist id does not look right.');
  }

  return { provider: 'youtube', playlistId: id, externalUrl: youtubePlaylistUrl(id) };
}
