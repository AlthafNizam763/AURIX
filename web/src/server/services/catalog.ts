import type { Document } from 'mongodb';

import { S, z } from '../http/validate';
import { iso } from '../utils/json';
import { tokensForSong } from '../utils/search';

/**
 * The shared song catalogue.
 *
 * ## Writes are merges, never overwrites
 *
 * `POST /catalog/songs` is called on every import, by every user, with whatever
 * metadata that user's source happened to carry. A Spotify import knows the
 * album and the duration; a YouTube import often knows neither. If the write
 * replaced the stored row, the same song would gain and lose its album depending
 * on who imported it last — and the catalogue would degrade as it grew.
 *
 * So [mergeDelta] only ever fills fields that are *empty*, and [preferRicher]
 * collapses duplicates within one batch by choosing the more complete of the
 * two. This is the one write path in the migration where the obvious
 * implementation — upsert the incoming document — is silently wrong.
 */

/** The song schema a client may submit. `.strip()` drops unknown fields. */
export const songIn = z
  .object({
    id: S.docId,
    title: z.string().max(500).default('Unknown track'),
    // Note this is an *array*, and the duration field is `duration` — the
    // catalogue song shape is not the same as `S.track`.
    artists: z.array(z.string().max(300)).max(50).default([]),
    album: z.string().max(500).default(''),
    duration: z
      .number()
      .int()
      .min(0)
      .max(24 * 60 * 60 * 1000)
      .default(0),
    artworkUrl: z.string().max(2048).default(''),
    source: z.string().max(32).default('aurix'),
    sourceId: z.string().max(220).default(''),
    externalUrl: z.string().max(2048).default(''),
    explicit: z.boolean().default(false),
    searchTokens: z.array(z.string().max(32)).max(200).default([]),
    spotifyId: z.string().max(220).optional(),
    youtubeVideoId: z.string().max(220).optional(),
    previewUrl: z.string().max(2048).optional(),
  })
  .strip();

export type SongIn = z.infer<typeof songIn>;

/** Maps `_id` to `id`, which is what the Dart models read. */
export function songOut(doc: Document | null | undefined): Document | null {
  if (!doc) return null;
  const { _id, ...rest } = doc;
  return {
    id: _id,
    ...rest,
    createdAt: iso(rest.createdAt),
    updatedAt: iso(rest.updatedAt),
  };
}

/**
 * The more complete of two submissions of the same song.
 *
 * Scored on the three fields that are most often missing. Used to collapse
 * duplicates *within one batch* before any of them reaches the database — two
 * upserts on one key inside a single `bulkWrite` would otherwise race each other
 * for the same row.
 */
export function preferRicher(a: SongIn, b: SongIn): SongIn {
  const score = (song: SongIn) =>
    (song.album ? 1 : 0) + (song.duration > 0 ? 1 : 0) + (song.artworkUrl ? 1 : 0);
  return score(b) > score(a) ? b : a;
}

/**
 * What an incoming song adds to the one already stored.
 *
 * Every clause is "set it if we have it and the stored row does not". Nothing
 * here can replace a populated field, which is what makes repeated imports
 * monotonically improve the catalogue rather than churn it.
 */
export function mergeDelta(incoming: SongIn, existing: Document): Document {
  const delta: Document = {};

  if (incoming.album && !existing.album) delta.album = incoming.album;
  if (incoming.duration > 0 && !(existing.duration > 0)) delta.duration = incoming.duration;
  if (incoming.artworkUrl && !existing.artworkUrl) delta.artworkUrl = incoming.artworkUrl;
  if (incoming.externalUrl && !existing.externalUrl) delta.externalUrl = incoming.externalUrl;
  if (incoming.spotifyId && !existing.spotifyId) delta.spotifyId = incoming.spotifyId;
  if (incoming.youtubeVideoId && !existing.youtubeVideoId) {
    delta.youtubeVideoId = incoming.youtubeVideoId;
  }
  if (incoming.previewUrl && !existing.previewUrl) delta.previewUrl = incoming.previewUrl;

  // Only when the album arrives, because the album is the only merged field
  // that participates in the token set. Recomputing on every delta would be
  // wasted work; never recomputing would leave the song unfindable by an album
  // name it has only just acquired.
  if (delta.album !== undefined) {
    delta.searchTokens = tokensForSong({
      title: incoming.title,
      artist: (incoming.artists ?? []).join(', '),
      album: incoming.album,
    });
  }

  return delta;
}
