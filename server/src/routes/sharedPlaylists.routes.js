import express from 'express';

import { collections } from '../db/mongo.js';
import { requireAuth } from '../middleware/auth.js';
import { S, q, validate, z } from '../middleware/validate.js';
import {
  namedFields,
  playlistOut,
  syncTrackCount,
  trackOut,
  writeTracksInOrder,
} from '../services/playlists.js';
import { limitOf, route } from '../utils/async.js';
import { forbidden, notFound } from '../utils/errors.js';
import { matchesResidual, normaliseAlbum, queryToken, residualWords } from '../utils/search.js';
import { log } from '../utils/logger.js';

/**
 * The shared playlist catalogue — the replacement for
 * `FirestoreGlobalPlaylistService`.
 *
 * ## Why this collection is not scoped to an account
 *
 * Discovery is the requirement. An imported playlist is a contribution to
 * AURIX's catalogue, not a private copy: User A imports "Love", and Users B and
 * C must be able to search it, open it and play it without being the importer.
 *
 * So provenance lives in *fields* rather than in the query. `importedByUserId`,
 * `importedBy` and `importedAt` record who brought a playlist in, and **not one
 * of them narrows who may read it.** Exactly two routes consult
 * `importedByUserId`: the delete, which only the importer may perform, and the
 * "playlists I imported" list, which is a presentation filter on the Library
 * screen rather than an access rule.
 *
 * That distinction — recorded, not enforcing — is the whole design, and it is
 * the one thing to preserve if these routes are ever rewritten.
 *
 * ## De-duplication is structural
 *
 * Document ids come from `PlaylistKey`, derived from (`source`, `sourceId`), so
 * the same source playlist imported by two accounts addresses one document.
 * There is no read-then-write window to lose: the id *is* the check, and two
 * devices importing at the same moment upsert the same row.
 */
const router = express.Router();
router.use(requireAuth);

const playlists = () => collections.globalPlaylists();
const tracks = () => collections.globalPlaylistTracks();

const SEARCH_FANOUT = 4;

// ---------------------------------------------------------------------------
// Reads — open to every signed-in account
// ---------------------------------------------------------------------------

router.get(
  '/search',
  validate({
    query: z.object({ q: z.string().max(200).default(''), limit: z.string().optional() }),
  }),
  route(async (req, res) => {
    const { q: query, limit: rawLimit } = q(req);
    const limit = limitOf(rawLimit, { fallback: 20, max: 100 });

    const token = queryToken(query);
    if (!token) return res.json({ playlists: [] });

    const residual = residualWords(query);
    const rows = await playlists()
      .find({ searchTokens: token })
      .limit(residual.length === 0 ? limit * 2 : limit * SEARCH_FANOUT)
      .toArray();

    const wanted = normaliseAlbum(query);
    const matched = rows.filter((row) =>
      matchesResidual(row.searchTitle ?? normaliseAlbum(row.name ?? ''), residual),
    );

    // Exact title first, then prefix, then everything else — and within each
    // band the fuller playlist wins. Ranking here rather than in the client
    // keeps the ordering identical for every caller.
    const score = (row) => {
      const title = row.searchTitle ?? normaliseAlbum(row.name ?? '');
      if (title === wanted) return 0;
      if (title.startsWith(wanted)) return 1;
      return 2;
    };
    matched.sort((a, b) => score(a) - score(b) || (b.trackCount ?? 0) - (a.trackCount ?? 0));

    res.json({ playlists: matched.slice(0, limit).map(playlistOut) });
  }),
);

/**
 * The shared-catalogue half of the duplicate-import check.
 *
 * Matched on (`source`, `sourceId`) first, and on the canonical `sourceUrl`
 * second — a link pasted with different tracking parameters normalises to the
 * same URL, so the second lookup catches an import the first would miss.
 */
router.get(
  '/find',
  validate({
    query: z.object({
      source: z.string().trim().max(32).optional(),
      sourceId: z.string().trim().max(220).optional(),
      sourceUrl: z.string().trim().max(2048).optional(),
    }),
  }),
  route(async (req, res) => {
    const { source, sourceId, sourceUrl } = q(req);

    let doc = null;
    if (source && sourceId) doc = await playlists().findOne({ source, sourceId });
    if (!doc && sourceUrl) doc = await playlists().findOne({ sourceUrl });

    res.json({ playlist: playlistOut(doc) });
  }),
);

/** Playlists a given account imported. A presentation filter, not an access rule. */
router.get(
  '/imported-by/:uid',
  validate({ params: z.object({ uid: S.uid }) }),
  route(async (req, res) => {
    const rows = await playlists()
      .find({ importedByUserId: req.params.uid })
      .sort({ importedAt: -1 })
      .limit(500)
      .toArray();
    res.json({ playlists: rows.map(playlistOut) });
  }),
);

router.get(
  '/:id',
  validate({ params: z.object({ id: S.docId }) }),
  route(async (req, res) => {
    res.json({ playlist: playlistOut(await playlists().findOne({ _id: req.params.id })) });
  }),
);

router.get(
  '/:id/tracks',
  validate({
    params: z.object({ id: S.docId }),
    query: z.object({ limit: z.string().optional() }),
  }),
  route(async (req, res) => {
    const rows = await tracks()
      .find({ playlistId: req.params.id })
      .sort({ position: 1 })
      .limit(limitOf(q(req).limit, { fallback: 2000, max: 5000 }))
      .toArray();
    res.json({ tracks: rows.map(trackOut) });
  }),
);

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/**
 * Creates or refreshes a shared playlist.
 *
 * The metadata half of the write is restricted to the account that first
 * imported the playlist. Everyone else's upsert touches `updatedAt` and nothing
 * more.
 *
 * That restriction is inherited verbatim from the Firestore rules, and the
 * reason is a race rather than a permission model: two accounts importing the
 * same playlist at once both pass the duplicate check, and the loser must not
 * rewrite the winner's name, cover and provenance a moment later. The
 * description is left alone even for the importer — see the `/synced` route.
 */
router.post(
  '/',
  validate({
    body: z.object({
      id: S.docId,
      source: z.string().trim().min(1).max(32),
      sourceId: z.string().trim().min(1).max(220),
      name: z.string().trim().max(200).default(''),
      description: z.string().trim().max(1000).default(''),
      coverUrl: S.url.default(''),
      sourceUrl: S.url.nullish(),
      importedBy: z.string().trim().max(120).default(''),
    }),
  }),
  route(async (req, res) => {
    const { id, source, sourceId, name, description, coverUrl, sourceUrl, importedBy } =
      req.body;
    const { uid } = req.user;
    const now = new Date();

    const existing = await playlists().findOne(
      { _id: id },
      { projection: { importedByUserId: 1 } },
    );

    if (existing) {
      const isImporter = existing.importedByUserId === uid;
      const $set = { updatedAt: now };

      if (isImporter) {
        if (name.trim()) Object.assign($set, namedFields(name));
        if (coverUrl) $set.coverUrl = coverUrl;
        if (sourceUrl) $set.sourceUrl = sourceUrl;
      }

      await playlists().updateOne({ _id: id }, { $set });
      log.info(`Existing shared playlist ${id}${isImporter ? ' refreshed' : ''}`, 'import');
      return res.json({ id, created: false });
    }

    await playlists().updateOne(
      { _id: id },
      {
        $set: { updatedAt: now },
        $setOnInsert: {
          ...namedFields(name),
          description,
          coverUrl,
          source,
          sourceId,
          sourceUrl: sourceUrl ?? '',
          trackCount: 0,
          // Provenance. Recorded once, never narrowing a read.
          importedByUserId: uid,
          importedBy,
          importedAt: now,
          createdAt: now,
        },
      },
      { upsert: true },
    );

    log.info(`Created shared playlist ${id}`, 'import');
    res.status(201).json({ id, created: true });
  }),
);

router.put(
  '/:id/tracks',
  validate({
    params: z.object({ id: S.docId }),
    body: z.object({
      tracks: z.array(z.object({ trackId: S.docId, track: S.track })).max(5000),
    }),
  }),
  route(async (req, res) => {
    const playlistId = req.params.id;
    const written = await writeTracksInOrder(tracks(), { playlistId }, req.body.tracks);
    await recount(playlistId);
    res.json({ written });
  }),
);

router.post(
  '/:id/tracks/remove',
  validate({
    params: z.object({ id: S.docId }),
    body: z.object({ trackIds: z.array(S.docId).max(5000) }),
  }),
  route(async (req, res) => {
    const playlistId = req.params.id;
    if (req.body.trackIds.length === 0) return res.json({ removed: 0 });

    const result = await tracks().deleteMany({
      playlistId,
      trackId: { $in: req.body.trackIds },
    });
    await recount(playlistId);
    res.json({ removed: result.deletedCount });
  }),
);

router.post(
  '/:id/synced',
  validate({
    params: z.object({ id: S.docId }),
    body: z.object({
      name: z.string().trim().max(200).optional(),
      coverUrl: S.url.optional(),
    }),
  }),
  route(async (req, res) => {
    const now = new Date();
    const $set = { syncedAt: now, updatedAt: now };
    if (req.body.name?.trim()) Object.assign($set, namedFields(req.body.name));
    if (req.body.coverUrl) $set.coverUrl = req.body.coverUrl;

    const result = await playlists().updateOne({ _id: req.params.id }, { $set });
    if (result.matchedCount === 0) throw notFound('That playlist is no longer in the catalogue.');
    res.status(204).end();
  }),
);

/**
 * Removes a playlist from the shared catalogue.
 *
 * The importer alone. This is the one route where `importedByUserId` is a
 * permission rather than a record, and it matches the Firestore rule it
 * replaces: a shared playlist other users are listening to must not be
 * removable by any of them.
 */
router.delete(
  '/:id',
  validate({ params: z.object({ id: S.docId }) }),
  route(async (req, res) => {
    const doc = await playlists().findOne(
      { _id: req.params.id },
      { projection: { importedByUserId: 1 } },
    );
    if (!doc) throw notFound('That playlist is no longer in the catalogue.');
    if (doc.importedByUserId !== req.user.uid) {
      throw forbidden('Only the account that imported this playlist can remove it.');
    }

    await tracks().deleteMany({ playlistId: req.params.id });
    await playlists().deleteOne({ _id: req.params.id });
    res.status(204).end();
  }),
);

async function recount(playlistId) {
  try {
    await syncTrackCount(playlists(), tracks(), { _id: playlistId }, { playlistId });
  } catch (error) {
    log.warn(`Could not sync shared track count for ${playlistId}`, 'import', error);
  }
}

export default router;
