import { cookies } from 'next/headers';
import { redirect } from 'next/navigation';
import jwt, { type JwtPayload } from 'jsonwebtoken';

import { assertConfigured, env } from '../config/env';
import type { UserDoc } from '../db/documents';
import { collections } from '../db/mongo';
import { log } from '../utils/logger';

/**
 * The admin portal's own session.
 *
 * ## Why the portal does not carry the app's tokens
 *
 * The obvious design is to sign in through `POST /auth/login` and keep the
 * access and refresh tokens the API returns. It is the wrong one here, for two
 * reasons that compound:
 *
 *  1. **A browser has nowhere safe to put them.** `localStorage` is readable by
 *     any script that gets onto the page, and an admin token is the one
 *     credential in AURIX that can repaint the app for every user.
 *  2. **Access tokens live 30 minutes and rotation needs a writable response.**
 *     Next.js can only set a cookie from a Server Action or a Route Handler,
 *     never while rendering a page — so a token that expires mid-session cannot
 *     be refreshed where it is noticed. The portal would bounce an
 *     administrator to the login screen every half hour.
 *
 * So the portal has a session of its own: an `httpOnly` cookie holding a JWT
 * this deployment signed, valid for [SESSION_HOURS], never readable by script,
 * and never accepted by the API. That last property is enforced rather than
 * assumed — the token carries `typ: 'admin_session'`, and `verifyAccessToken`
 * requires `typ: 'access'`, so a stolen portal cookie cannot be replayed as a
 * bearer token against `/api/v1`.
 *
 * ## The revocation property is preserved
 *
 * `requireAdmin` re-reads `users.isAdmin` from the database on **every** portal
 * request, exactly as the API's `withAdmin` does. The cookie proves who you are;
 * the database decides what you may do. An administrator demoted while their
 * session is open loses access on their next click, not in eight hours.
 */

const COOKIE = 'aurix_admin';
const SESSION_TYPE = 'admin_session';

/**
 * How long a portal session lasts.
 *
 * A working day rather than the API's 30 minutes. The trade is deliberate: this
 * token cannot be used against the API, it is not readable by script, and the
 * thing it protects is re-checked against the database on every request — so
 * the cost of a longer window is small, and the cost of a shorter one is an
 * administrator signing in repeatedly while editing a theme.
 */
const SESSION_HOURS = 8;

interface AdminClaims extends JwtPayload {
  sub: string;
  typ?: string;
}

export interface AdminSession {
  uid: string;
  name: string;
  email: string;
}

/** Mints the cookie. Called only after a password and `isAdmin` have been checked. */
export async function startSession(user: UserDoc): Promise<void> {
  assertConfigured();

  const token = jwt.sign(
    { sub: user.uid, typ: SESSION_TYPE },
    env.jwtSecret,
    { expiresIn: `${SESSION_HOURS}h` },
  );

  const jar = await cookies();
  jar.set(COOKIE, token, {
    // Not readable by script. The whole point.
    httpOnly: true,
    // Sent over TLS only, in production. Omitted locally so http://localhost
    // development works at all.
    secure: env.isProduction,
    // `lax` rather than `strict`: the portal's Server Actions POST to the page
    // they are on, which same-site covers, and `strict` would drop the cookie
    // when an administrator follows a link into the portal from elsewhere.
    // Next.js additionally verifies the Origin header on every Server Action,
    // which is the actual CSRF defence here.
    sameSite: 'lax',
    path: '/admin',
    maxAge: SESSION_HOURS * 60 * 60,
  });
}

export async function endSession(): Promise<void> {
  const jar = await cookies();
  jar.delete({ name: COOKIE, path: '/admin' });
}

/**
 * The signed-in administrator, or `null`.
 *
 * Verifies the cookie **and** re-reads the account. Both halves are load
 * bearing: the signature says the cookie was issued by this deployment and has
 * not expired, and the read says the account still exists and is still an
 * administrator.
 */
export async function currentAdmin(): Promise<AdminSession | null> {
  const jar = await cookies();
  const token = jar.get(COOKIE)?.value;
  if (!token) return null;

  let claims: AdminClaims;
  try {
    claims = jwt.verify(token, env.jwtSecret) as AdminClaims;
  } catch {
    return null;
  }

  // A portal cookie is not an API token and an API token is not a portal
  // cookie. Without this check an access token pasted into the cookie would
  // sign somebody in.
  if (claims.typ !== SESSION_TYPE) return null;

  try {
    const users = await collections.users();
    const user = await users.findOne(
      { uid: String(claims.sub) },
      { projection: { uid: 1, name: 1, email: 1, isAdmin: 1 } },
    );

    if (!user?.isAdmin) return null;

    return { uid: user.uid, name: user.name ?? '', email: user.email ?? '' };
  } catch (error) {
    // A database failure must not be read as "not an administrator" and
    // silently bounce someone to a login screen that will also fail.
    log.error('Could not verify the admin session', 'admin', error);
    return null;
  }
}

/**
 * The signed-in administrator, or a redirect to the login screen.
 *
 * Every portal page and every Server Action calls this. A page that forgets is
 * a page with no `admin` to render, which does not compile — the same property
 * the API's wrappers have.
 */
export async function requireAdmin(): Promise<AdminSession> {
  const admin = await currentAdmin();
  if (!admin) redirect('/admin/login');
  return admin;
}
