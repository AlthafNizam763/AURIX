import { collections } from '../db/mongo.js';
import { verifyAccessToken } from '../services/tokens.js';
import { adminOnly, forbidden, unauthorized } from '../utils/errors.js';

/**
 * Resolves `req.user` from the `Authorization: Bearer …` header.
 *
 * ## The property this middleware exists to guarantee
 *
 * Every per-user collection is queried with a uid, and **that uid comes from
 * here and from nowhere else.** No route handler reads a uid out of a request
 * body or a path parameter and uses it as a filter. That single rule is what
 * replaces `firestore.rules`: the old security model was a server-side rule
 * trying to catch a hostile client's write, and the new one is that a client
 * cannot express a query about another account at all.
 *
 * Where a route does take a `:uid` in its path — the profile read, for example
 * — [requireSelf] asserts it equals `req.user.uid` before the handler runs.
 */
function bearer(req) {
  const header = req.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return null;
  const token = header.slice(7).trim();
  return token.length > 0 ? token : null;
}

export function requireAuth(req, _res, next) {
  const token = bearer(req);
  if (!token) return next(unauthorized());

  try {
    const payload = verifyAccessToken(token);
    req.user = { uid: payload.sub, email: payload.email, isAdmin: payload.admin === true };
    return next();
  } catch (error) {
    return next(error);
  }
}

/**
 * Populates `req.user` when a token is present and valid, and carries on
 * regardless when it is not.
 *
 * For routes that are public but *richer* when signed in. The theme read is the
 * one that matters: the app fetches the palette before it has a session, and
 * refusing it would leave the login screen unstyled.
 */
export function optionalAuth(req, _res, next) {
  const token = bearer(req);
  if (!token) return next();
  try {
    const payload = verifyAccessToken(token);
    req.user = { uid: payload.sub, email: payload.email, isAdmin: payload.admin === true };
  } catch {
    // A stale token on a public route is not an error — the caller simply gets
    // the anonymous view.
  }
  return next();
}

/**
 * Admin gate for the theme and branding writes.
 *
 * Re-reads the user document rather than trusting the `admin` claim alone. The
 * claim is there so ordinary requests do not pay for a lookup; a route that can
 * repaint the app for every user is worth one read, and it is what makes a
 * revoked admin lose access immediately instead of at the next token refresh.
 */
export async function requireAdmin(req, _res, next) {
  try {
    if (!req.user?.uid) throw unauthorized();
    const user = await collections
      .users()
      .findOne({ uid: req.user.uid }, { projection: { isAdmin: 1 } });
    if (!user?.isAdmin) throw adminOnly();
    req.user.isAdmin = true;
    return next();
  } catch (error) {
    return next(error);
  }
}

/** Asserts a `:uid` path parameter names the caller. */
export function requireSelf(paramName = 'uid') {
  return (req, _res, next) => {
    if (!req.user?.uid) return next(unauthorized());
    if (req.params[paramName] !== req.user.uid) {
      return next(forbidden('That is not your account.'));
    }
    return next();
  };
}
