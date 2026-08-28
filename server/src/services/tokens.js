import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';

import { env } from '../config/env.js';
import { collections } from '../db/mongo.js';
import { tokenExpired, unauthorized } from '../utils/errors.js';

/**
 * Token issue and verification.
 *
 * ## Two tokens, two lifetimes, two secrets
 *
 * The **access token** is a short-lived JWT the client attaches to every
 * request. It is stateless by design: verifying it is a signature check with no
 * database round trip, which is what keeps a library screen's worth of requests
 * cheap.
 *
 * The **refresh token** is long-lived and therefore *stateful*. Only a SHA-256
 * of it is stored, in `refreshTokens`, with a TTL index that lets Mongo expire
 * it. Storing the hash rather than the token is the same discipline as storing
 * a password hash: a leaked database backup must not yield working sessions.
 *
 * The two are signed with different secrets so a refresh token can never be
 * presented where an access token is expected, even though both are JWTs.
 *
 * ## Rotation
 *
 * [rotateRefreshToken] deletes the presented token in the same operation that
 * issues its replacement, and refuses if the delete matched nothing. That makes
 * replay detectable: a token used twice fails the second time, because the
 * first use removed it.
 */

const REFRESH_TYPE = 'refresh';
const ACCESS_TYPE = 'access';

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function issueAccessToken(user) {
  return jwt.sign(
    {
      sub: user.uid,
      email: user.email,
      // Carried in the token so `requireAdmin` does not need a user read on
      // every admin request. The cost is that a demotion takes effect at the
      // next refresh rather than instantly — acceptable for a role that is
      // granted deliberately and rarely revoked, and the admin write routes
      // re-read the user document anyway.
      admin: user.isAdmin === true,
      typ: ACCESS_TYPE,
    },
    env.jwtSecret,
    { expiresIn: env.accessTokenTtl },
  );
}

export function verifyAccessToken(token) {
  try {
    const payload = jwt.verify(token, env.jwtSecret);
    if (payload.typ !== ACCESS_TYPE) throw unauthorized('Wrong token type.');
    return payload;
  } catch (error) {
    if (error?.name === 'TokenExpiredError') throw tokenExpired();
    if (error instanceof Error && error.name === 'ApiError') throw error;
    throw unauthorized('That session token is not valid.');
  }
}

export async function issueRefreshToken(uid, { device } = {}) {
  const expiresAt = new Date(Date.now() + env.refreshTokenDays * 24 * 60 * 60 * 1000);
  const token = jwt.sign({ sub: uid, typ: REFRESH_TYPE }, env.refreshSecret, {
    expiresIn: `${env.refreshTokenDays}d`,
  });

  await collections.refreshTokens().insertOne({
    tokenHash: sha256(token),
    uid,
    device: device ?? null,
    createdAt: new Date(),
    expiresAt,
  });

  return { token, expiresAt };
}

/**
 * Verifies a refresh token and swaps it for a fresh pair.
 *
 * The delete-then-issue order matters: if the delete matches nothing the token
 * was already spent (or revoked by a sign-out elsewhere), and issuing a new one
 * would resurrect a session the user ended.
 */
export async function rotateRefreshToken(token) {
  let payload;
  try {
    payload = jwt.verify(token, env.refreshSecret);
  } catch (error) {
    if (error?.name === 'TokenExpiredError') throw tokenExpired();
    throw unauthorized('That refresh token is not valid.');
  }
  if (payload.typ !== REFRESH_TYPE) throw unauthorized('Wrong token type.');

  const removed = await collections.refreshTokens().deleteOne({ tokenHash: sha256(token) });
  if (removed.deletedCount === 0) {
    throw unauthorized('That session has already ended. Sign in again.');
  }

  return payload.sub;
}

export async function revokeRefreshToken(token) {
  if (!token) return;
  await collections.refreshTokens().deleteOne({ tokenHash: sha256(token) });
}

/** Ends every session for an account — used on password change. */
export async function revokeAllRefreshTokens(uid) {
  await collections.refreshTokens().deleteMany({ uid });
}

// ---------------------------------------------------------------------------
// Action tokens — password reset and email verification
// ---------------------------------------------------------------------------

/**
 * A single-use, time-limited token delivered out of band (by email).
 *
 * Opaque random bytes rather than a JWT, and only its hash is stored. A JWT
 * here would be self-verifying, which sounds convenient and means the token
 * cannot be revoked once sent — exactly wrong for "I did not request this
 * password reset".
 */
export async function issueActionToken(uid, kind) {
  const token = crypto.randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + env.actionTokenMinutes * 60 * 1000);

  // One live token per (uid, kind). Requesting a second reset link invalidates
  // the first, so a link forwarded or leaked earlier stops working.
  await collections.actionTokens().deleteMany({ uid, kind });
  await collections.actionTokens().insertOne({
    tokenHash: sha256(token),
    uid,
    kind,
    createdAt: new Date(),
    expiresAt,
  });

  return { token, expiresAt };
}

export async function consumeActionToken(token, kind) {
  if (typeof token !== 'string' || token.length === 0) {
    throw unauthorized('That link is not valid.');
  }
  const record = await collections
    .actionTokens()
    .findOneAndDelete({ tokenHash: sha256(token), kind });

  if (!record) throw unauthorized('That link is not valid or has already been used.');
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    throw tokenExpired();
  }
  return record.uid;
}

export const ACTION = { resetPassword: 'reset_password', verifyEmail: 'verify_email' };
