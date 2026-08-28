import crypto from 'node:crypto';
import express from 'express';

import { collections } from '../db/mongo.js';
import { requireAuth } from '../middleware/auth.js';
import { S, q, validate, z } from '../middleware/validate.js';
import {
  appendTracks,
  namedFields,
  playlistOut,
  positionBetween,
  rebalance,
  syncTrackCount,
  trackOut,
  writeTracksInOrder,
} from '../services/playlists.js';
import { limitOf, route } from '../utils/async.js';
import { notFound } from '../utils/errors.js';
import { log } from '../utils/logger.js';

/**
 * The user's own playlists — the replacement for `FirestorePlaylistService`.
 *
 * Every query here is scoped by `uid` from the verified token. A playlist id in
 * the path is never sufficient on its own: the filter is always
 * `{ uid, playlistId }`, so naming another user's playlist id returns 404
 * rather than their data. That is the same guarantee `/users/{uid}/playlists`
 * gave in Firestore, expressed as a query instead of as a rule.
 */
const router = express.Router();
router.use(requireAuth);

const playlists = () => collections.userPlaylists();
const tracks = () => collections.userPlaylistTracks();

/** Playlist ids the client did not supply. Never begins `pl_` — see `PlaylistKey`. */
const newPlaylistId = () => crypto.randomBytes(15).toString('base64url').slice(0, 20);

const scopeOf = (req) => ({ uid: req.user.uid, playlistId: req.params.id });

async function requirePlaylist(req) {
  const doc = await playlists().findOne({ uid: req.user.uid, playlistId: req.params.id });
  if (!doc) throw notFound('That playlist no longer exists.');
  return doc;
}

/** Count corrections are cosmetic — never fail a completed write over one. */
async function recount(req) {
  try {
    await syncTrackCount(
      playlists(),
      tracks(),
      { uid: req.user.uid, playlistId: req.params.id },
      scopeOf(req),
    );
  } catch (error) {
    log.warn(`Could not sync track count for ${req.params.id}`, 'playlists', error);
  }
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/**
 * Every playlist the user owns, newest edit first.
 *
 * Ordered by `updatedAt` rather than by name: a library screen is a list of
 * things you are working with, and the one you touched last is the one you are
 * most likely to want. The screen re-sorts locally when the user asks for
 * something else.
 */
router.get(
  '/',
  route(async (req, res) => {
    const rows = await playlists()
      .find({ uid: req.user.uid })
      .sort({ updatedAt: -1 })
      .limit(500)
      .toArray();
    res.json({ playlists: rows.map(playlistOut) });
  }),
);

/**
 * The duplicate-import check.
 *
 * Answers "have I already imported this?" against the user's own playlists.
 * The shared-catalogue half of the same question lives on
 * `/shared-playlists/find`, and the import flow asks both.
 */
router.get(
  '/find',
  validate({
    query: z.object({
      source: z.string().trim().min(1).max(32),
      sourceId: z.string().trim().min(1).max(220),
    }),
  }),
  route(async (req, res) => {
    const { source, sourceId } = q(req);
    const doc = await playlists().findOne({ uid: req.user.uid, source, sourceId });
    res.json({ playlist: playlistOut(doc) });
  }),
);

router.get(
  '/:id',
  route(async (req, res) => {
    res.json({ playlist: playlistOut(await requirePlaylist(req)) });
  }),
);

router.get(
  '/:id/tracks',
  validate({ query: z.object({ limit: z.string().optional() }) }),
  route(async (req, res) => {
    const rows = await tracks()
      .find(scopeOf(req))
      .sort({ position: 1 })
      .limit(limitOf(q(req).limit, { fallback: 2000, max: 5000 }))
      .toArray();
    res.json({ tracks: rows.map(trackOut) });
  }),
);

// ---------------------------------------------------------------------------
// Playlist lifecycle
// ---------------------------------------------------------------------------

router.post(
  '/',
  validate({
    body: z.object({
      name: z.string().trim().min(1).max(200),
      description: z.string().trim().max(1000).default(''),
      coverUrl: S.url.default(''),
      source: z.string().trim().max(32).default('aurix'),
      sourceId: z.string().trim().max(220).nullish(),
      sourceUrl: S.url.nullish(),
    }),
  }),
  route(async (req, res) => {
    const now = new Date();
    const playlistId = newPlaylistId();

    await playlists().insertOne({
      uid: req.user.uid,
      playlistId,
      ...namedFields(req.body.name),
      description: req.body.description,
      coverUrl: req.body.coverUrl,
      source: req.body.source,
      sourceId: req.body.sourceId ?? null,
      sourceUrl: req.body.sourceUrl ?? null,
      trackCount: 0,
      createdAt: now,
      updatedAt: now,
    });

    log.info(`Created playlist ${playlistId}`, 'playlists');
    res.status(201).json({ id: playlistId });
  }),
);

router.patch(
  '/:id',
  validate({
    body: z.object({
      name: z.string().trim().min(1).max(200),
      description: z.string().trim().max(1000).optional(),
    }),
  }),
  route(async (req, res) => {
    const result = await playlists().updateOne(
      { uid: req.user.uid, playlistId: req.params.id },
      {
        $set: {
          ...namedFields(req.body.name),
          ...(req.body.description !== undefined
            ? { description: req.body.description }
            : {}),
          updatedAt: new Date(),
        },
      },
    );
    if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
    res.status(204).end();
  }),
);

/**
 * Records the outcome of a re-sync against the playlist's source.
 *
 * Separate from the rename route because a sync updates *provenance* rather
 * than the user's own edits. The description is deliberately not touched: the
 * user may have edited it here, and overwriting an edit with a stale line from
 * the source is worse than leaving the line stale.
 */
router.post(
  '/:id/synced',
  validate({
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

    const result = await playlists().updateOne(
      { uid: req.user.uid, playlistId: req.params.id },
      { $set },
    );
    if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
    res.status(204).end();
  }),
);

router.put(
  '/:id/cover',
  validate({ body: z.object({ coverUrl: S.url }) }),
  route(async (req, res) => {
    const result = await playlists().updateOne(
      { uid: req.user.uid, playlistId: req.params.id },
      { $set: { coverUrl: req.body.coverUrl, updatedAt: new Date() } },
    );
    if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
    res.status(204).end();
  }),
);

/**
 * Deletes a playlist and everything in it.
 *
 * The track rows go first. Firestore had the same requirement for a different
 * reason — it does not cascade to subcollections — and it holds here too:
 * `userPlaylistTracks` rows keyed on a deleted playlist id would be invisible
 * orphans that reappear in full if an id were ever reused.
 */
router.delete(
  '/:id',
  route(async (req, res) => {
    const scope = scopeOf(req);
    await tracks().deleteMany(scope);
    const result = await playlists().deleteOne({
      uid: req.user.uid,
      playlistId: req.params.id,
    });
    if (result.deletedCount === 0) throw notFound('That playlist no longer exists.');
    res.status(204).end();
  }),
);

// ---------------------------------------------------------------------------
// Track membership
// ---------------------------------------------------------------------------

const trackEntry = z.object({ trackId: S.docId, track: S.track });

router.post(
  '/:id/tracks',
  validate({ body: trackEntry }),
  route(async (req, res) => {
    await requirePlaylist(req);
    await appendTracks(tracks(), scopeOf(req), [req.body]);
    await recount(req);
    res.status(204).end();
  }),
);

router.post(
  '/:id/tracks/bulk',
  validate({ body: z.object({ tracks: z.array(trackEntry).max(5000) }) }),
  route(async (req, res) => {
    await requirePlaylist(req);
    const added = await appendTracks(tracks(), scopeOf(req), req.body.tracks);
    await recount(req);
    res.json({ added });
  }),
);

/** Replaces the ordering wholesale — the import and re-sync path. */
router.put(
  '/:id/tracks',
  validate({ body: z.object({ tracks: z.array(trackEntry).max(5000) }) }),
  route(async (req, res) => {
    await requirePlaylist(req);
    const written = await writeTracksInOrder(tracks(), scopeOf(req), req.body.tracks);
    await recount(req);
    res.json({ written });
  }),
);

router.delete(
  '/:id/tracks/:trackId',
  validate({ params: z.object({ id: z.string(), trackId: S.docId }) }),
  route(async (req, res) => {
    await tracks().deleteOne({ ...scopeOf(req), trackId: req.params.trackId });
    await recount(req);
    res.status(204).end();
  }),
);

router.post(
  '/:id/tracks/remove',
  validate({ body: z.object({ trackIds: z.array(S.docId).max(5000) }) }),
  route(async (req, res) => {
    const { trackIds } = req.body;
    if (trackIds.length === 0) return res.json({ removed: 0 });

    const result = await tracks().deleteMany({
      ...scopeOf(req),
      trackId: { $in: trackIds },
    });
    await recount(req);
    res.json({ removed: result.deletedCount });
  }),
);

/**
 * Moves one track within the playlist.
 *
 * The fractional-position algorithm from `FirestorePlaylistService.reorder`,
 * moved server-side. It ran on the client before because only the client knew
 * the order the user was looking at; it still supplies that order, but the two
 * neighbour lookups it needed are now local queries rather than two more round
 * trips over the network.
 *
 * The normal case is a single write. When the gap between the neighbours has
 * collapsed — reachable after roughly fifty drops between the same pair — the
 * whole list is renumbered once and the move becomes expressible again.
 */
router.post(
  '/:id/reorder',
  validate({
    body: z.object({
      orderedTrackIds: z.array(S.docId).max(5000),
      from: z.number().int().min(0),
      to: z.number().int().min(0),
    }),
  }),
  route(async (req, res) => {
    const { orderedTrackIds, from, to } = req.body;
    if (from === to || from < 0 || from >= orderedTrackIds.length) {
      return res.json({ rebalanced: false });
    }

    const scope = scopeOf(req);

    // The list as it *will* be, so "the neighbours" means the neighbours at
    // the destination rather than at the origin. An off-by-one here puts the
    // track one place from where it was dropped — the classic reorder bug.
    const moved = orderedTrackIds[from];
    const reordered = orderedTrackIds.filter((_, index) => index !== from);
    const target = Math.max(0, Math.min(to, reordered.length));
    reordered.splice(target, 0, moved);

    const beforeId = target > 0 ? reordered[target - 1] : null;
    const afterId = target + 1 < reordered.length ? reordered[target + 1] : null;

    const positionOf = async (trackId) => {
      if (!trackId) return null;
      const row = await tracks().findOne(
        { ...scope, trackId },
        { projection: { position: 1 } },
      );
      return typeof row?.position === 'number' ? row.position : null;
    };

    const next = positionBetween(await positionOf(beforeId), await positionOf(afterId));

    if (next === null) {
      log.info(
        `Rebalancing playlist ${req.params.id} (${reordered.length} tracks)`,
        'playlists',
      );
      await rebalance(tracks(), scope, reordered);
      await playlists().updateOne(
        { uid: req.user.uid, playlistId: req.params.id },
        { $set: { updatedAt: new Date() } },
      );
      return res.json({ rebalanced: true });
    }

    await tracks().updateOne({ ...scope, trackId: moved }, { $set: { position: next } });
    await playlists().updateOne(
      { uid: req.user.uid, playlistId: req.params.id },
      { $set: { updatedAt: new Date() } },
    );
    res.json({ rebalanced: false, position: next });
  }),
);

export default router;
