import express from 'express';

import { requireAuth, requireSelf } from '../middleware/auth.js';
import { S, validate, z } from '../middleware/validate.js';
import { collections } from '../db/mongo.js';
import { accountView, requireUser, updateUser } from '../services/users.js';
import { route } from '../utils/async.js';
import { badRequest } from '../utils/errors.js';

/**
 * The AURIX profile — the replacement for `FirestoreProfileService`.
 *
 * The profile and the account are one document now, where Firebase kept them in
 * two places (the Auth record held the email and verification state, the
 * Firestore document held the name and avatar). Collapsing them removes the
 * class of bug that split created: a display name changed in one store and not
 * the other.
 *
 * `ensureProfile` survives as `POST /ensure` because the app still calls it on
 * every sign-in, and it still does the same job — return the profile, creating
 * the missing pieces rather than failing when an older account predates a field.
 */
const router = express.Router();

router.use(requireAuth);

router.get(
  '/me',
  route(async (req, res) => {
    res.json({ user: await accountView(await requireUser(req.user.uid)) });
  }),
);

/**
 * Reads another account's profile.
 *
 * Guarded by [requireSelf], so it currently only ever returns the caller's own
 * — the app has no "view someone else's profile" screen. It is a separate route
 * from `/me` because `AuthRepository` reads by uid, and keeping the shape means
 * a future public-profile view is a change to this guard rather than a new
 * endpoint.
 */
router.get(
  '/:uid',
  requireSelf('uid'),
  route(async (req, res) => {
    res.json({ user: await accountView(await requireUser(req.params.uid)) });
  }),
);

/**
 * Returns the profile, filling in anything an older record is missing.
 *
 * Idempotent, and called on every sign-in. The `$setOnInsert`-style defaults
 * here are what let a record written by an earlier build gain a field without a
 * migration script.
 */
router.post(
  '/ensure',
  validate({
    body: z.object({
      name: S.displayName.optional(),
      email: S.email.optional(),
    }),
  }),
  route(async (req, res) => {
    const user = await requireUser(req.user.uid);
    const patch = {};

    // A name supplied by the client only fills a *gap*. It never overwrites a
    // name the user has set — sign-in must not silently rename an account back
    // to whatever the device happened to remember.
    if (!user.name && req.body.name) patch.name = req.body.name;
    if (!user.avatarId) patch.avatarId = 'avatar_01';

    const result = Object.keys(patch).length > 0 ? await updateUser(user.uid, patch) : user;
    res.json({ user: await accountView(result) });
  }),
);

router.patch(
  '/me',
  validate({
    body: z.object({
      name: S.displayName.optional(),
      avatarId: z.string().trim().max(64).optional(),
    }),
  }),
  route(async (req, res) => {
    const patch = {};
    if (req.body.name !== undefined) patch.name = req.body.name;
    if (req.body.avatarId !== undefined) patch.avatarId = req.body.avatarId;
    if (Object.keys(patch).length === 0) throw badRequest('Nothing to update.');
    res.json({ user: await accountView(await updateUser(req.user.uid, patch)) });
  }),
);

router.put(
  '/me/avatar',
  validate({ body: z.object({ avatarId: z.string().trim().min(1).max(64) }) }),
  route(async (req, res) => {
    res.json({
      user: await accountView(await updateUser(req.user.uid, { avatarId: req.body.avatarId })),
    });
  }),
);

/**
 * A cheap summary the Profile screen shows without opening each collection.
 *
 * Three counted queries rather than three full reads — the equivalent of the
 * Firestore aggregate `count()` this replaces, and for the same reason: the
 * screen wants a number, not the rows.
 */
router.get(
  '/me/stats',
  route(async (req, res) => {
    const { uid } = req.user;
    const [liked, playlists, played] = await Promise.all([
      collections.likedTracks().countDocuments({ uid }),
      collections.userPlaylists().countDocuments({ uid }),
      collections.recentlyPlayed().countDocuments({ uid }),
    ]);
    res.json({ likedTracks: liked, playlists, recentlyPlayed: played });
  }),
);

export default router;
