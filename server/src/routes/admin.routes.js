import express from 'express';

import { collections } from '../db/mongo.js';
import { requireAdmin, requireAuth } from '../middleware/auth.js';
import { S, q, validate, z } from '../middleware/validate.js';
import { accountView, accountViews } from '../services/users.js';
import { limitOf, route } from '../utils/async.js';
import { badRequest, notFound } from '../utils/errors.js';
import { log } from '../utils/logger.js';

/**
 * Administration — user roles and a database overview.
 *
 * Everything here is behind [requireAdmin], which re-reads the user document
 * rather than trusting the token's `admin` claim. See the note there for why
 * these particular routes are worth the extra read.
 */
const router = express.Router();
router.use(requireAuth, requireAdmin);

router.get(
  '/stats',
  route(async (_req, res) => {
    const [users, admins, liked, playlists, sharedPlaylists, songs] = await Promise.all([
      collections.users().countDocuments(),
      collections.users().countDocuments({ isAdmin: true }),
      collections.likedTracks().countDocuments(),
      collections.userPlaylists().countDocuments(),
      collections.globalPlaylists().countDocuments(),
      collections.catalogSongs().countDocuments(),
    ]);
    res.json({ users, admins, likedTracks: liked, playlists, sharedPlaylists, songs });
  }),
);

router.get(
  '/users',
  validate({
    query: z.object({
      q: z.string().trim().max(200).optional(),
      limit: z.string().optional(),
    }),
  }),
  route(async (req, res) => {
    const { q: search, limit } = q(req);

    // Anchored and escaped. An unescaped user string in a `$regex` is a denial
    // of service waiting to happen — `(a+)+$` against a long field is the
    // classic catastrophic-backtracking case — and an unanchored one cannot
    // use the index at all.
    const filter = search
      ? {
          $or: [
            { email: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
            { name: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
          ],
        }
      : {};

    const rows = await collections
      .users()
      .find(filter)
      .sort({ createdAt: -1 })
      .limit(limitOf(limit, { fallback: 50, max: 200 }))
      .toArray();

    res.json({ users: await accountViews(rows) });
  }),
);

/**
 * Grants or revokes administrator access.
 *
 * Refuses to remove the last administrator. Without that check a deployment can
 * lock itself out of its own theme configuration with one click, and the only
 * way back is a Mongo shell.
 */
router.post(
  '/users/:uid/admin',
  validate({ params: z.object({ uid: S.uid }), body: z.object({ isAdmin: z.boolean() }) }),
  route(async (req, res) => {
    const { uid } = req.params;
    const { isAdmin } = req.body;

    if (!isAdmin) {
      const admins = await collections.users().countDocuments({ isAdmin: true });
      const target = await collections.users().findOne({ uid }, { projection: { isAdmin: 1 } });
      if (target?.isAdmin && admins <= 1) {
        throw badRequest('That is the only administrator — promote another account first.');
      }
    }

    const updated = await collections
      .users()
      .findOneAndUpdate(
        { uid },
        { $set: { isAdmin, updatedAt: new Date() } },
        { returnDocument: 'after' },
      );
    if (!updated) throw notFound('No such account.');

    log.info(`${req.user.uid} set isAdmin=${isAdmin} on ${uid}`, 'admin');
    res.json({ user: await accountView(updated) });
  }),
);

function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export default router;
