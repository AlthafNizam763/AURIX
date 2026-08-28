import express from 'express';
import rateLimit from 'express-rate-limit';

import { env, signInMethods } from '../config/env.js';
import { collections } from '../db/mongo.js';
import { requireAuth } from '../middleware/auth.js';
import { S, validate, z } from '../middleware/validate.js';
import { detachIdentity } from '../services/identities.js';
import { sendEmailVerification, sendPasswordReset } from '../services/mailer.js';
import { buildSession } from '../services/session.js';
import {
  ACTION,
  consumeActionToken,
  issueActionToken,
  revokeAllRefreshTokens,
  revokeRefreshToken,
  rotateRefreshToken,
} from '../services/tokens.js';
import {
  accountView,
  createUser,
  requireUser,
  setPassword,
  updateUser,
  userByEmail,
  verifyPassword,
} from '../services/users.js';
import { route } from '../utils/async.js';
import { badRequest, invalidCredentials, unauthorized } from '../utils/errors.js';
import { log } from '../utils/logger.js';

import linkRoutes from './auth.link.routes.js';
import oauthRoutes from './auth.oauth.routes.js';
import phoneRoutes from './auth.phone.routes.js';

/**
 * Identity for AURIX.
 *
 * This router is the replacement for Firebase Authentication, and it is the
 * part of the migration with no automatic path: Firebase does not export
 * password hashes in a form another system can verify, so **existing Firebase
 * accounts cannot be carried over.** Everyone registers once more. That is
 * stated in `docs/MONGODB_MIGRATION.md` and surfaced in the app's own sign-in
 * copy rather than being left for a user to discover as a failed login.
 *
 * What is preserved is the *behaviour* the app already depended on: the same
 * operations, the same failure kinds, and the same rule that a failed sign-in
 * never reveals whether the address is registered.
 */
const router = express.Router();

/**
 * Rate limits, per IP.
 *
 * Firebase applied these on Google's side and the app never had to think about
 * them. Now they are ours, and the credential routes are the ones that matter:
 * without a limit, `POST /login` is an offline password cracker with a network
 * hop. bcrypt at cost 12 makes each guess expensive for us too, so the limiter
 * also protects the server's own CPU.
 */
const credentialLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 20 : 200,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many attempts. Try again in a few minutes.' } },
});

const resetLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: env.isProduction ? 5 : 100,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many reset requests. Try again later.' } },
});

// The payload every successful sign-in and refresh returns now lives in
// `services/session.js`, because it is no longer this router's alone: phone
// sign-in, all four social providers and the account-link confirmation all
// have to produce the identical shape, and the client has exactly one piece
// of code that reads it. See the note there.

// ---------------------------------------------------------------------------
// The other ways in
// ---------------------------------------------------------------------------
//
// Mounted here rather than beside `/auth` in `app.js` so that everything under
// `/api/v1/auth` is reachable from this file, and so the ordering rule below
// is visible: these come *before* the `/:something` routes further down.

router.use('/phone', phoneRoutes);
router.use('/oauth', oauthRoutes);
router.use('/link', linkRoutes);

/**
 * Which ways in this deployment can actually serve.
 *
 * Public, and read by the login screen before anyone has signed in — the same
 * reason `GET /theme` is public. A provider whose credentials are absent is
 * reported as unavailable rather than offered and then failing in a browser
 * tab, which is the difference between a button that is not there and a button
 * that is broken.
 *
 * Nothing secret is disclosed. A client id is public by definition and is not
 * returned here either; this is a list of names.
 */
router.get(
  '/methods',
  route(async (_req, res) => {
    res.json({ methods: signInMethods() });
  }),
);

/**
 * Removes a way in.
 *
 * Refuses to remove the last one — see [detachIdentity], where the reasoning
 * lives. The failure mode it guards against is permanent: an account with no
 * identity left has no sign-in path and no recovery path either.
 */
router.delete(
  '/methods/:provider',
  requireAuth,
  validate({
    params: z.object({
      provider: z.enum(['password', 'phone', 'google', 'apple', 'facebook', 'github']),
    }),
  }),
  route(async (req, res) => {
    await detachIdentity({ uid: req.user.uid, provider: req.params.provider });
    log.info(`Unlinked ${req.params.provider} from ${req.user.uid}`, 'auth');
    res.json({ user: await accountView(await requireUser(req.user.uid)) });
  }),
);

// ---------------------------------------------------------------------------
// Register / sign in / sign out
// ---------------------------------------------------------------------------

router.post(
  '/register',
  credentialLimiter,
  validate({
    body: z.object({
      email: S.email,
      password: S.password,
      name: S.displayName,
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const { email, password, name, device } = req.body;
    const user = await createUser({ email, password, name });

    // Fire-and-forget: a verification email that fails to send must not fail
    // the registration. The account exists, the user is signed in, and the
    // app offers "resend" on the profile screen.
    issueActionToken(user.uid, ACTION.verifyEmail)
      .then(({ token }) => sendEmailVerification(user.email, token))
      .catch((error) => log.warn('Could not start email verification', 'auth', error));

    log.info(`Registered ${user.email}${user.isAdmin ? ' (admin)' : ''}`, 'auth');
    res.status(201).json(await buildSession(user, { device }));
  }),
);

router.post(
  '/login',
  credentialLimiter,
  validate({
    body: z.object({
      email: S.email,
      // Not `S.password`: an existing account may predate any policy change,
      // and rejecting a short password at *sign-in* would lock its owner out
      // while telling an attacker the length rule.
      password: z.string().min(1).max(200),
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const { email, password, device } = req.body;
    const user = await userByEmail(email);

    // One error for "no such account" and for "wrong password", and the hash
    // comparison runs either way. Both halves matter: distinct messages leak
    // which addresses are registered, and skipping bcrypt on a missing account
    // leaks the same thing through response timing.
    const ok = await verifyPassword(password, user?.passwordHash ?? '');
    if (!user || !ok) throw invalidCredentials();

    res.json(await buildSession(user, { device }));
  }),
);

router.post(
  '/refresh',
  validate({ body: z.object({ refreshToken: z.string().min(1) }) }),
  route(async (req, res) => {
    const uid = await rotateRefreshToken(req.body.refreshToken);
    const user = await requireUser(uid);
    res.json(await buildSession(user));
  }),
);

router.post(
  '/logout',
  validate({ body: z.object({ refreshToken: z.string().min(1).optional() }) }),
  route(async (req, res) => {
    await revokeRefreshToken(req.body.refreshToken);
    res.status(204).end();
  }),
);

// ---------------------------------------------------------------------------
// The signed-in account
// ---------------------------------------------------------------------------

router.get(
  '/me',
  requireAuth,
  route(async (req, res) => {
    res.json({ user: await accountView(await requireUser(req.user.uid)) });
  }),
);

router.patch(
  '/me',
  requireAuth,
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

// ---------------------------------------------------------------------------
// Passwords
// ---------------------------------------------------------------------------

router.post(
  '/password/change',
  requireAuth,
  credentialLimiter,
  validate({
    body: z.object({
      // Optional since social and phone sign-in arrived. An account created by
      // "Continue with Google" has no password, and there is nothing for its
      // owner to type here — so this route doubles as "set a password", which
      // is how such an account gains one. It is safe because the caller holds
      // a live session for the account, which is the same standard the reset
      // link meets.
      //
      // It stays *required* wherever a password exists: this must never
      // become a way to replace a password without knowing it.
      currentPassword: z.string().min(1).max(200).optional(),
      newPassword: S.password,
    }),
  }),
  route(async (req, res) => {
    const user = await requireUser(req.user.uid);
    const hasPassword =
      typeof user.passwordHash === 'string' && user.passwordHash.length > 0;

    if (hasPassword) {
      if (!req.body.currentPassword) {
        throw unauthorized('Enter your current password to change it.');
      }
      const ok = await verifyPassword(req.body.currentPassword, user.passwordHash);
      if (!ok) throw unauthorized('That current password is not correct.');
    }

    await setPassword(user.uid, req.body.newPassword);

    // Every other session ends. A password change is what a user does after
    // suspecting someone else has their account, and leaving that someone
    // signed in on another device would defeat the point. The caller keeps
    // working because the response carries a fresh pair.
    await revokeAllRefreshTokens(user.uid);
    res.json(await buildSession(await requireUser(user.uid)));
  }),
);

router.post(
  '/password/forgot',
  resetLimiter,
  validate({ body: z.object({ email: S.email }) }),
  route(async (req, res) => {
    const user = await userByEmail(req.body.email);

    // Always the same response. Reporting "no such account" here turns this
    // endpoint into an address-enumeration oracle, which is the one thing a
    // password-reset form must not be.
    const answer = {
      ok: true,
      message: 'If that address has an AURIX account, a reset link is on its way.',
    };

    if (!user) return res.json(answer);

    const { token } = await issueActionToken(user.uid, ACTION.resetPassword);
    const sent = await sendPasswordReset(user.email, token);

    // Outside production only, and only when there is no mail transport: the
    // flow has to be testable on a machine with no SMTP. `env.isProduction`
    // is the gate that keeps this from being an account-takeover endpoint.
    if (!sent && !env.isProduction) answer.devToken = token;

    res.json(answer);
  }),
);

router.post(
  '/password/reset',
  resetLimiter,
  validate({ body: z.object({ token: z.string().min(1), password: S.password }) }),
  route(async (req, res) => {
    const uid = await consumeActionToken(req.body.token, ACTION.resetPassword);
    await setPassword(uid, req.body.password);
    await revokeAllRefreshTokens(uid);
    res.json({ ok: true });
  }),
);

// ---------------------------------------------------------------------------
// Email verification
// ---------------------------------------------------------------------------

router.post(
  '/email/verify/send',
  requireAuth,
  resetLimiter,
  route(async (req, res) => {
    const user = await requireUser(req.user.uid);
    if (user.emailVerified) return res.json({ ok: true, alreadyVerified: true });

    const { token } = await issueActionToken(user.uid, ACTION.verifyEmail);
    const sent = await sendEmailVerification(user.email, token);

    const answer = { ok: true };
    if (!sent && !env.isProduction) answer.devToken = token;
    res.json(answer);
  }),
);

router.post(
  '/email/verify',
  validate({ body: z.object({ token: z.string().min(1) }) }),
  route(async (req, res) => {
    const uid = await consumeActionToken(req.body.token, ACTION.verifyEmail);
    const user = await updateUser(uid, { emailVerified: true });
    res.json({ ok: true, user: await accountView(user) });
  }),
);

// ---------------------------------------------------------------------------
// Account deletion
// ---------------------------------------------------------------------------

router.delete(
  '/me',
  requireAuth,
  // Optional for the same reason it is optional on `password/change`: an
  // account created by a social sign-in or a phone code has no password, and
  // requiring one here would leave its owner unable to delete their own
  // account — with no way to acquire the thing being demanded.
  validate({ body: z.object({ password: z.string().min(1).max(200).optional() }) }),
  route(async (req, res) => {
    const user = await requireUser(req.user.uid);
    const hasPassword =
      typeof user.passwordHash === 'string' && user.passwordHash.length > 0;

    // Where a password exists it is still demanded, and still checked. A live
    // session is a weaker claim than a re-typed password — it is what a
    // borrowed, unlocked phone has — and deletion is irreversible.
    if (hasPassword && !(await verifyPassword(req.body.password ?? '', user.passwordHash))) {
      throw unauthorized('That password is not correct.');
    }

    const { uid } = user;
    // Everything the account owns. The two shared collections are deliberately
    // untouched: a playlist someone imported into the shared catalogue is a
    // contribution other users are listening to, and deleting an account must
    // not delete their library. The provenance fields keep pointing at a uid
    // that no longer resolves, which is exactly what "imported by a former
    // user" should look like.
    await Promise.all([
      collections.likedTracks().deleteMany({ uid }),
      collections.recentlyPlayed().deleteMany({ uid }),
      collections.userPlaylists().deleteMany({ uid }),
      collections.userPlaylistTracks().deleteMany({ uid }),
      collections.refreshTokens().deleteMany({ uid }),
      collections.actionTokens().deleteMany({ uid }),
      // The linked provider accounts. Not deleting these would leave rows
      // whose unique `(provider, subject)` index blocks the same person from
      // ever signing up again with the Google account they used before.
      collections.identities().deleteMany({ uid }),
    ]);
    await collections.users().deleteOne({ uid });

    log.info(`Deleted account ${uid}`, 'auth');
    res.status(204).end();
  }),
);

export default router;
