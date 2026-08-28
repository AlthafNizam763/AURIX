import express from 'express';

import { collections } from '../db/mongo.js';
import { requireAuth } from '../middleware/auth.js';
import { S, q, validate, z } from '../middleware/validate.js';
import { limitOf, route, iso } from '../utils/async.js';
import {
  matchesResidual,
  normaliseAlbum,
  queryToken,
  residualWords,
  tokensForSong,
} from '../utils/search.js';
import { log } from '../utils/logger.js';

/**
 * The shared song catalogue — the replacement for `FirestoreCatalogService`.
 *
 * ## Shared, and deliberately so
 *
 * This collection is not owned by the account reading it. It is what makes an
 * import a *contribution* to AURIX rather than a private copy: a song imported
 * by one user is findable in global search by every user, and stored once
 * rather than once per importer.
 *
 * So reads are filtered by nothing but the query, and writes are open to any
 * signed-in account — with the shape enforced here, by the schema below, where
 * `firestore.rules` used to enforce it. What a client can no longer do is
 * *replace* an existing row: the upsert merges, and the merge only ever fills
 * gaps. That is what stops one import from erasing what another contributed.
 */
const router = express.Router();
router.use(requireAuth);

const songs = () => collections.catalogSongs();

/** How much extra to read when a query has words the index cannot match. */
const SEARCH_FANOUT = 4;

/** Mirrors `Song.fromDocument`. */
function songOut(doc) {
  if (!doc) return null;
  const { _id, ...rest } = doc;
  return {
    id: _id,
    ...rest,
    createdAt: iso(rest.createdAt),
    updatedAt: iso(rest.updatedAt),
  };
}

/** The document body a client may write. Everything else is dropped. */
const songIn = z
  .object({
    id: S.docId,
    title: z.string().max(500).default('Unknown track'),
    artists: z.array(z.string().max(300)).max(50).default([]),
    album: z.string().max(500).default(''),
    duration: z.number().int().min(0).max(24 * 60 * 60 * 1000).default(0),
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

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/**
 * Songs matching a query, as an indexed lookup rather than a scan.
 *
 * One equality match on the precomputed token array, bounded by `limit`. A
 * keystroke therefore costs at most `limit` document reads no matter how large
 * the catalogue grows — the requirement this design exists to meet, and the
 * reason the token array survived the migration unchanged.
 *
 * A multi-word query is matched on its most selective word and the remaining
 * words are applied in memory over the returned page. Mongo could express an
 * `$all` over every word, and that is deliberately not done: `$all` requires
 * every word to be an indexed token, so a query whose second word is a stop
 * word would start returning nothing. Same query, same results, different
 * database — over-fetching by [SEARCH_FANOUT] is the cheap mitigation, exactly
 * as it was before.
 */
router.get(
  '/songs/search',
  validate({
    query: z.object({ q: z.string().max(200).default(''), limit: z.string().optional() }),
  }),
  route(async (req, res) => {
    const { q: query, limit: rawLimit } = q(req);
    const limit = limitOf(rawLimit, { fallback: 20, max: 100 });

    const token = queryToken(query);
    if (!token) return res.json({ songs: [] });

    const residual = residualWords(query);
    const rows = await songs()
      .find({ searchTokens: token })
      .limit(residual.length === 0 ? limit : limit * SEARCH_FANOUT)
      .toArray();

    const out = [];
    for (const row of rows) {
      const haystack = normaliseAlbum(
        `${row.title ?? ''} ${(row.artists ?? []).join(', ')} ${row.album ?? ''}`,
      );
      if (!matchesResidual(haystack, residual)) continue;
      out.push(songOut(row));
      if (out.length >= limit) break;
    }

    res.json({ songs: out });
  }),
);

/**
 * Reads many songs by id.
 *
 * Used by the import path to find out which of the songs it is about to write
 * already exist. Firestore chunked this at its 30-id `whereIn` limit; `$in` has
 * no such cap, so one request covers a whole playlist.
 */
router.post(
  '/songs/batch',
  validate({ body: z.object({ ids: z.array(S.docId).max(2000) }) }),
  route(async (req, res) => {
    const ids = [...new Set(req.body.ids)];
    if (ids.length === 0) return res.json({ songs: {} });

    const rows = await songs().find({ _id: { $in: ids } }).toArray();
    const out = {};
    for (const row of rows) out[row._id] = songOut(row);
    res.json({ songs: out });
  }),
);

router.get(
  '/songs/:id',
  validate({ params: z.object({ id: S.docId }) }),
  route(async (req, res) => {
    res.json({ song: songOut(await songs().findOne({ _id: req.params.id })) });
  }),
);

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/**
 * Of two descriptions of one song, the one carrying more.
 *
 * Reached when a single playlist lists the same song twice — genuinely common
 * in long compilations — and the two entries differ in completeness.
 */
function preferRicher(a, b) {
  const score = (song) =>
    (song.album ? 1 : 0) + (song.duration > 0 ? 1 : 0) + (song.artworkUrl ? 1 : 0);
  return score(b) > score(a) ? b : a;
}

/**
 * The subset of fields a *second* import of the same song may update.
 *
 * A re-import must be able to improve a row — better artwork, a duration the
 * first source did not have, the provider id from the other service — without
 * erasing what is already there. So every rule below is "write only when this
 * copy has a value and the stored row does not". Nothing is ever overwritten
 * with nothing.
 *
 * `source`, `createdAt`, `id` and `title` are never rewritten. The first three
 * record how the row came to exist; the title is the identity the key was
 * derived from, and changing it would make the document disagree with its own
 * `_id`.
 */
function mergeDelta(incoming, existing) {
  const delta = {};

  if (incoming.album && !existing.album) delta.album = incoming.album;
  if (incoming.duration > 0 && !(existing.duration > 0)) delta.duration = incoming.duration;
  if (incoming.artworkUrl && !existing.artworkUrl) delta.artworkUrl = incoming.artworkUrl;
  if (incoming.externalUrl && !existing.externalUrl) delta.externalUrl = incoming.externalUrl;

  // The capability ids are the point of merging at all: this is how a song
  // known to Spotify gains its YouTube id and becomes playable by either
  // provider.
  if (incoming.spotifyId && !existing.spotifyId) delta.spotifyId = incoming.spotifyId;
  if (incoming.youtubeVideoId && !existing.youtubeVideoId) {
    delta.youtubeVideoId = incoming.youtubeVideoId;
  }
  if (incoming.previewUrl && !existing.previewUrl) delta.previewUrl = incoming.previewUrl;

  // Re-tokenised whenever anything searchable improved, so a row that gained
  // an album name becomes findable by it.
  if (delta.album !== undefined) {
    delta.searchTokens = tokensForSong({
      title: incoming.title,
      artist: (incoming.artists ?? []).join(', '),
      album: incoming.album,
    });
  }

  return delta;
}

/**
 * Writes songs into the catalogue, creating or improving each.
 *
 * Returns the number of documents actually written — new plus genuinely
 * updated — which is smaller than `songs.length` whenever an import
 * re-encounters songs the catalogue already had in full. A re-import of an
 * unchanged 200-track playlist therefore costs one read and **zero** writes.
 */
router.post(
  '/songs',
  validate({ body: z.object({ songs: z.array(songIn).max(2000) }) }),
  route(async (req, res) => {
    const incoming = req.body.songs;
    if (incoming.length === 0) return res.json({ written: 0, created: 0, updated: 0 });

    // De-duplicated first: the same song twice in one payload would be two
    // operations on one `_id` inside a single bulkWrite, racing each other.
    const byId = new Map();
    for (const song of incoming) {
      const seen = byId.get(song.id);
      byId.set(song.id, seen ? preferRicher(seen, song) : song);
    }

    const ids = [...byId.keys()];
    const existingRows = await songs().find({ _id: { $in: ids } }).toArray();
    const existing = new Map(existingRows.map((row) => [row._id, row]));

    const now = new Date();
    const operations = [];
    let created = 0;
    let updated = 0;

    for (const song of byId.values()) {
      const current = existing.get(song.id);

      if (!current) {
        const { id, ...body } = song;
        operations.push({
          updateOne: {
            filter: { _id: id },
            update: {
              $set: { ...body, updatedAt: now },
              // Server clock. A shared collection cannot be ordered by a
              // client's, and one device with a wrong date would otherwise
              // reorder the catalogue for everybody.
              $setOnInsert: { createdAt: now },
            },
            upsert: true,
          },
        });
        created++;
        continue;
      }

      const delta = mergeDelta(song, current);
      // An empty delta means the catalogue already knows everything this copy
      // could contribute. Writing it anyway would bump `updatedAt` for no
      // change at all.
      if (Object.keys(delta).length === 0) continue;

      operations.push({
        updateOne: {
          filter: { _id: song.id },
          update: { $set: { ...delta, updatedAt: now } },
        },
      });
      updated++;
    }

    if (operations.length > 0) await songs().bulkWrite(operations, { ordered: false });

    log.info(
      `Catalogue: ${created} new, ${updated} improved, ${byId.size - created - updated} unchanged`,
      'catalog',
    );

    res.json({ written: created + updated, created, updated });
  }),
);

export default router;
