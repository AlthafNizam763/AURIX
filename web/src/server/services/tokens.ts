import crypto from 'node:crypto';

import jwt, { type JwtPayload } from 'jsonwebtoken';

import { assertConfigured, env } from '../config/env';
import { collections } from '../db/mongo';
import type { ActionKind, UserDoc } from '../db/documents';
import { ApiError, tokenExpired, unauthorized } from '../utils/errors';

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
 * The two are signed with **different secrets**, so a refresh token can never
 * be presented where an access token is expected even though both are JWTs.
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

export interface AccessClaims extends JwtPayload {
  sub: string;
  email?: string;
  admin?: boolean;
  typ?: string;
}

function sha256(value: string): string {
  return crypto.createHash('sha256').update(value).digest('hex');
}

export function issueAccessToken(user: UserDoc): string {
  // Signing is the other point, besides connecting, where a deployment missing
  // its configuration must say so clearly rather than mint a token with an
  // empty secret. See the note in config/env.ts on why this is not checked at
  // module load.
  assertConfigured();

  return jwt.sign(
    {
      sub: user.uid,
      email: user.email,
      // Carried in the token so ordinary requests do not pay for a user read.
      // The cost is that a demotion takes effect at the next refresh rather
      // than instantly — acceptable for a role that is granted deliberately and
      // rarely revoked, and `withAdmin` re-reads the user document anyway.
      admin: user.isAdmin === true,
      typ: ACCESS_TYPE,
    },
    env.jwtSecret,
    { expiresIn: env.accessTokenTtl as jwt.SignOptions['expiresIn'] },
  );
}

export function verifyAccessToken(token: string): AccessClaims {
  try {
    const payload = jwt.verify(token, env.jwtSecret) as AccessClaims;
    if (payload.typ !== ACCESS_TYPE) throw unauthorized('Wrong token type.');
    return payload;
  } catch (error) {
    // An ApiError raised above — the wrong-token-type case — must pass through
    // rather than be reclassified by the generic branch below.
    if (error instanceof ApiError) throw error;
    if ((error as Error)?.name === 'TokenExpiredError') throw tokenExpired();
    throw unauthorized('That session token is not valid.');
  }
}

export async function issueRefreshToken(
  uid: string,
  { device }: { device?: string | null } = {},
): Promise<{ token: string; expiresAt: Date }> {
  assertConfigured();

  const expiresAt = new Date(Date.now() + env.refreshTokenDays * 24 * 60 * 60 * 1000);

  const token = jwt.sign(
    {
      sub: uid,
      typ: REFRESH_TYPE,
      /**
       * A nonce, and it is load-bearing rather than decorative.
       *
       * Without it the payload is `{ sub, typ, iat, exp }`, and `iat`/`exp` have
       * **one-second resolution** — so two refresh tokens issued for the same
       * account within the same second are byte-for-byte identical. That is not
       * hypothetical: signing in on two devices at once, a client retrying a
       * login, or any automated flow hits it immediately.
       *
       * Both consequences are bad. The unique index on `tokenHash` catches the
       * second insert and turns an ordinary sign-in into a 500. And were the
       * index not there, two devices would be issued *the same token* — so the
       * first to rotate it would silently sign the other out, because rotation
       * deletes the row.
       *
       * The Express server has this bug (`server/src/services/tokens.js`); it
       * was found by porting the code and testing it, and is fixed here.
       */
      jti: crypto.randomBytes(16).toString('base64url'),
    },
    env.refreshSecret,
    { expiresIn: `${env.refreshTokenDays}d` },
  );

  const refreshTokens = await collections.refreshTokens();
  await refreshTokens.insertOne({
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
export async function rotateRefreshToken(token: string): Promise<string> {
  let payload: JwtPayload;
  try {
    payload = jwt.verify(token, env.refreshSecret) as JwtPayload;
  } catch (error) {
    if ((error as Error)?.name === 'TokenExpiredError') throw tokenExpired();
    throw unauthorized('That refresh token is not valid.');
  }
  if (payload.typ !== REFRESH_TYPE) throw unauthorized('Wrong token type.');

  const refreshTokens = await collections.refreshTokens();
  const removed = await refreshTokens.deleteOne({ tokenHash: sha256(token) });
  if (removed.deletedCount === 0) {
    throw unauthorized('That session has already ended. Sign in again.');
  }

  return String(payload.sub);
}

export async function revokeRefreshToken(token: string | undefined): Promise<void> {
  if (!token) return;
  const refreshTokens = await collections.refreshTokens();
  await refreshTokens.deleteOne({ tokenHash: sha256(token) });
}

/** Ends every session for an account — used on password change and reset. */
export async function revokeAllRefreshTokens(uid: string): Promise<void> {
  const refreshTokens = await collections.refreshTokens();
  await refreshTokens.deleteMany({ uid });
}

// ---------------------------------------------------------------------------
// Action tokens — password reset and email verification
// ---------------------------------------------------------------------------

export const ACTION = {
  resetPassword: 'reset_password',
  verifyEmail: 'verify_email',
} as const satisfies Record<string, ActionKind>;

/**
 * A single-use, time-limited token delivered out of band (by email).
 *
 * Opaque random bytes rather than a JWT, and only its hash is stored. A JWT
 * here would be self-verifying, which sounds convenient and means the token
 * cannot be revoked once sent — exactly wrong for "I did not request this
 * password reset".
 */
export async function issueActionToken(
  uid: string,
  kind: ActionKind,
): Promise<{ token: string; expiresAt: Date }> {
  const token = crypto.randomBytes(32).toString('base64url');
  const expiresAt = new Date(Date.now() + env.actionTokenMinutes * 60 * 1000);

  const actionTokens = await collections.actionTokens();
  // One live token per (uid, kind). Requesting a second reset link invalidates
  // the first, so a link forwarded or leaked earlier stops working.
  await actionTokens.deleteMany({ uid, kind });
  await actionTokens.insertOne({
    tokenHash: sha256(token),
    uid,
    kind,
    createdAt: new Date(),
    expiresAt,
  });

  return { token, expiresAt };
}

export async function consumeActionToken(token: string, kind: ActionKind): Promise<string> {
  if (typeof token !== 'string' || token.length === 0) {
    throw unauthorized('That link is not valid.');
  }

  const actionTokens = await collections.actionTokens();
  const record = await actionTokens.findOneAndDelete({ tokenHash: sha256(token), kind });

  if (!record) throw unauthorized('That link is not valid or has already been used.');
  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    throw tokenExpired();
  }
  return record.uid;
}
