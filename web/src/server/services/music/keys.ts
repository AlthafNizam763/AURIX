import crypto from 'node:crypto';

import type { MusicProviderId } from '../../config/env';

/**
 * Document ids for imported playlists and songs.
 *
 * ## This is a port, and it must stay one
 *
 * These are the same two derivations as `PlaylistKey` and `TrackKey` in
 * `mobile/lib/data/models/`, character for character. That is not tidiness — it
 * is the deduplication contract from §7 of the import requirements:
 *
 *   * `provider + providerPlaylistId` is a playlist's external identity, so the
 *     same playlist imported twice lands on **one** document;
 *   * `provider + providerTrackId` is a song's, so a song already in the
 *     catalogue is reused rather than duplicated.
 *
 * The client derives ids for playlists the user builds *in AURIX*, and the
 * server derives them for playlists imported *into* AURIX. If the two ever
 * disagreed, the same Spotify playlist would occupy one document when imported
 * from the app and a different one when imported through this API — and the
 * duplicate-prevention this whole design rests on would quietly stop working.
 *
 * `test/music-keys.test.ts` pins the two implementations against the same
 * vectors. Change one and that test fails, which is the point of it.
 */

/** What every shared-catalogue playlist id starts with. Mirrors `PlaylistKey.prefix`. */
export const PLAYLIST_PREFIX = 'pl_';

/** Ids that are safe to use verbatim. Mirrors `PlaylistKey._safe`. */
const SAFE = /^[A-Za-z0-9._~-]{1,120}$/;

/** Mirrors `TrackKey._sanitize`. */
function sanitize(value: string): string {
  const cleaned = value
    .replace(/[^A-Za-z0-9._~-]/g, '-')
    .replace(/-{2,}/g, '-')
    .replace(/^-+|-+$/g, '');
  if (!cleaned) return '';
  return cleaned.length <= 200 ? cleaned : cleaned.slice(0, 200);
}

/** Mirrors `TrackKey._normalise`. */
const normalise = (value: string): string =>
  value.toLowerCase().trim().replace(/\s+/g, '-');

/** Mirrors `PlaylistKey._hash` — SHA-1, first 24 hex characters. */
const hash = (value: string): string =>
  crypto.createHash('sha1').update(value, 'utf8').digest('hex').slice(0, 24);

/**
 * The shared-catalogue document id for a playlist.
 *
 * `pl_spotify_22WMPdyCLdKfeRraLxZbMw`. Readable on purpose: a Mongo shell
 * session should not need a lookup table to find the playlist someone is asking
 * about.
 */
export function playlistKey(provider: MusicProviderId, providerPlaylistId: string): string {
  const trimmed = providerPlaylistId.trim();
  const body = trimmed && SAFE.test(trimmed) && !trimmed.startsWith('__') ? trimmed : hash(trimmed);
  return `${PLAYLIST_PREFIX}${provider}_${body}`;
}

/**
 * The catalogue document id for a track the provider could identify.
 *
 * Provider-qualified because two services can hand out the same id string, and
 * an unqualified key would merge two unrelated songs into one document.
 */
export function trackKey(provider: MusicProviderId, providerTrackId: string): string {
  return `${provider}_${sanitize(providerTrackId)}`;
}

/**
 * The catalogue id for a track with no usable provider id.
 *
 * Derived from what the track *is*, so that the same song arriving from two
 * sources without ids collapses into one row rather than two. Not a hash, for
 * the same reason as above; the collision cost is bounded and benign — two
 * genuinely different songs sharing a title and an artist become one library
 * row, which is also what a person would call them.
 */
export function metadataKey(title: string, artist: string): string {
  const slug = sanitize(`${normalise(title)}-${normalise(artist)}`);
  return slug ? `aurix_${slug}` : 'aurix_untitled';
}
