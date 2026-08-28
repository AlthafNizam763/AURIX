import express from 'express';

import { collections } from '../db/mongo.js';
import { requireAuth } from '../middleware/auth.js';
import { S, q, validate, z } from '../middleware/validate.js';
import { limitOf, route, iso } from '../utils/async.js';
import { log } from '../utils/logger.js';

/**
 * The user's own library — liked songs and play history.
 *
 * The replacement for `FirestoreLibraryService`. Two collections, both keyed on
 * `uid`, and **the uid is always `req.user.uid`** — never a value from the
 * request. See the note in `middleware/auth.js` for why that one rule is what
 * replaced the Firestore ownership rule.
 */
const router = express.Router();
router.use(requireAuth);

/** Strips the storage keys a client should not see, and stamps the id. */
function trackOut(doc) {
  const { _id, uid, trackId, playlistId, position, ...rest } = doc;
  return { id: trackId, ...rest, createdAt: iso(rest.createdAt) };
}

// ---------------------------------------------------------------------------
// Liked songs
// ---------------------------------------------------------------------------

router.get(
  '/liked',
  validate({ query: z.object({ limit: z.string().optional() }) }),
  route(async (req, res) => {
    const rows = await collections
      .likedTracks()
      .find({ uid: req.user.uid })
      // Newest first — the order Liked Songs has always shown, and the order
      // the `uid_createdAt` index is built to serve.
      .sort({ createdAt: -1 })
      .limit(limitOf(q(req).limit, { fallback: 500, max: 2000 }))
      .toArray();

    res.json({ tracks: rows.map(trackOut) });
  }),
);

/**
 * Likes a track.
 *
 * An upsert on `(uid, trackId)`, which is what makes liking idempotent — the
 * property `TrackKey` bought when the document id was derived from the track.
 * `$setOnInsert` on `createdAt` is the other half: liking a song that is
 * already liked must not move it to the top of the list.
 */
router.put(
  '/liked/:trackId',
  validate({
    params: z.object({ trackId: S.docId }),
    body: S.track,
  }),
  route(async (req, res) => {
    const { uid } = req.user;
    const { trackId } = req.params;

    await collections.likedTracks().updateOne(
      { uid, trackId },
      {
        $set: { ...req.body, uid, trackId, updatedAt: new Date() },
        $setOnInsert: { createdAt: new Date() },
      },
      { upsert: true },
    );

    res.status(204).end();
  }),
);

router.delete(
  '/liked/:trackId',
  validate({ params: z.object({ trackId: S.docId }) }),
  route(async (req, res) => {
    await collections
      .likedTracks()
      .deleteOne({ uid: req.user.uid, trackId: req.params.trackId });
    res.status(204).end();
  }),
);

router.get(
  '/liked/:trackId',
  validate({ params: z.object({ trackId: S.docId }) }),
  route(async (req, res) => {
    const found = await collections
      .likedTracks()
      .findOne({ uid: req.user.uid, trackId: req.params.trackId }, { projection: { _id: 1 } });
    res.json({ liked: found !== null });
  }),
);

/**
 * Which of these track ids the user has liked.
 *
 * One request for a whole screen's worth of hearts. The Firestore version had
 * to chunk into `whereIn` batches of thirty; Mongo's `$in` has no such limit,
 * so the cap here is only the request-body sanity bound.
 */
router.post(
  '/liked/among',
  validate({ body: z.object({ trackIds: z.array(S.docId).max(1000) }) }),
  route(async (req, res) => {
    const { trackIds } = req.body;
    if (trackIds.length === 0) return res.json({ likedIds: [] });

    const rows = await collections
      .likedTracks()
      .find({ uid: req.user.uid, trackId: { $in: trackIds } }, { projection: { trackId: 1 } })
      .toArray();

    res.json({ likedIds: rows.map((row) => row.trackId) });
  }),
);

// ---------------------------------------------------------------------------
// Play history
// ---------------------------------------------------------------------------

/** Matches `ApiLibraryService.historyLimit` on the client. Keep the two in step. */
const HISTORY_LIMIT = 200;

router.get(
  '/recently-played',
  validate({ query: z.object({ limit: z.string().optional() }) }),
  route(async (req, res) => {
    const rows = await collections
      .recentlyPlayed()
      .find({ uid: req.user.uid })
      .sort({ playedAt: -1 })
      .limit(limitOf(q(req).limit, { fallback: 50, max: HISTORY_LIMIT }))
      .toArray();

    res.json({
      entries: rows.map((row) => ({
        ...trackOut(row),
        playedAt: iso(row.playedAt),
        position: row.position ?? 0,
      })),
    });
  }),
);

/**
 * Records a play.
 *
 * The document id is the **track**, not the play, so playing one song ten times
 * leaves one row whose `playedAt` moves. That is what the feature is: every
 * consumer wants distinct tracks in recency order, so collapsing on write keeps
 * the collection bounded by distinct tracks rather than by total plays, and
 * removes the de-duplication the Spotify-backed shelf used to do on read.
 *
 * The cost — the history cannot answer "how many times did I play this" —
 * is unchanged from the Firestore design, and nothing in AURIX asks.
 */
router.post(
  '/recently-played',
  validate({
    body: z.object({
      trackId: S.docId,
      track: S.track,
      position: z.number().int().min(0).default(0),
    }),
  }),
  route(async (req, res) => {
    const { uid } = req.user;
    const { trackId, track, position } = req.body;

    await collections.recentlyPlayed().updateOne(
      { uid, itemId: trackId },
      {
        $set: {
          ...track,
          uid,
          itemId: trackId,
          trackId,
          playedAt: new Date(),
          position,
          duration: track.durationMs ?? 0,
        },
        $setOnInsert: { createdAt: new Date() },
      },
      { upsert: true },
    );

    // Housekeeping, off the critical path of pressing play — the caller gets
    // its 204 without waiting for the trim.
    trim(uid).catch((error) => log.debug(`History trim failed: ${error.message}`, 'library'));

    res.status(204).end();
  }),
);

async function trim(uid) {
  const total = await collections.recentlyPlayed().countDocuments({ uid });
  if (total <= HISTORY_LIMIT) return;

  const excess = await collections
    .recentlyPlayed()
    .find({ uid }, { projection: { _id: 1 } })
    .sort({ playedAt: -1 })
    .skip(HISTORY_LIMIT)
    .toArray();

  if (excess.length === 0) return;
  await collections
    .recentlyPlayed()
    .deleteMany({ _id: { $in: excess.map((row) => row._id) } });
}

router.delete(
  '/recently-played',
  route(async (req, res) => {
    await collections.recentlyPlayed().deleteMany({ uid: req.user.uid });
    res.status(204).end();
  }),
);

export default router;
