import { collections } from '../db/mongo';
import type { RouteContext } from '../http/respond';
import { handler } from '../http/respond';
import { verifyAccessToken } from '../services/tokens';
import { adminOnly, forbidden, unauthorized } from '../utils/errors';

/**
 * Authentication, as handler wrappers.
 *
 * ## The property this module exists to guarantee
 *
 * Every per-user collection is queried with a uid, and **that uid comes from
 * here and from nowhere else.** No route handler reads a uid out of a request
 * body or a path parameter and uses it as a filter. That single rule is what
 * replaced `firestore.rules`: the old security model was a server-side rule
 * trying to catch a hostile client's write, and this one is that a client
 * cannot express a query about another account at all.
 *
 * Where a route does take a `:uid` in its path — the profile read — [withSelf]
 * asserts it equals the caller's before the handler runs.
 *
 * ## Why wrappers rather than middleware
 *
 * Express composed these as `router.use(requireAuth)`, which applied to every
 * route mounted after it and made "is this route authenticated?" a property of
 * where the file sat in a router tree. Next.js route handlers are exported
 * functions with no such tree, so authentication becomes a wrapper around the
 * export:
 *
 * ```ts
 * export const GET = withAuth(async (request, { auth }) => { … });
 * ```
 *
 * That is more explicit and, for this codebase, safer: a route file that forgets
 * to wrap has no `auth` to destructure and does not compile, whereas a route
 * misfiled in an Express tree silently served unauthenticated.
 *
 * `middleware.ts` is deliberately **not** used for this. Next's middleware runs
 * on the Edge runtime, where neither the Mongo driver nor `jsonwebtoken`'s
 * verification can run — and an auth check that has to be duplicated in the
 * handler anyway is a second place to get it wrong.
 */

/** Who the caller is, resolved from the bearer token. */
export interface Auth {
  uid: string;
  email?: string;
  isAdmin: boolean;
}

export interface AuthContext<P = Record<string, string>> extends RouteContext<P> {
  auth: Auth;
}

export interface OptionalAuthContext<P = Record<string, string>> extends RouteContext<P> {
  auth: Auth | null;
}

/** Extracts the token from `Authorization: Bearer …`. */
function bearer(request: Request): string | null {
  const header = request.headers.get('authorization') ?? '';
  if (!header.toLowerCase().startsWith('bearer ')) return null;
  const token = header.slice(7).trim();
  return token.length > 0 ? token : null;
}

function authFrom(token: string): Auth {
  const payload = verifyAccessToken(token);
  return {
    uid: String(payload.sub),
    email: payload.email,
    isAdmin: payload.admin === true,
  };
}

/**
 * Requires a valid access token.
 *
 * Throws `unauthenticated` when there is none and `token_expired` when there was
 * one and it has lapsed — the client branches on the difference, refreshing in
 * the second case and signing out in the first.
 */
export function withAuth<P = Record<string, string>>(
  fn: (request: Request, context: AuthContext<P>) => Promise<Response> | Response,
) {
  return handler<P>(async (request, context) => {
    const token = bearer(request);
    if (!token) throw unauthorized();
    return fn(request, { ...context, auth: authFrom(token) });
  });
}

/**
 * Populates `auth` when a token is present and valid, and carries on regardless
 * when it is not.
 *
 * For routes that are public but *richer* when signed in. The theme read is the
 * one that matters: the app fetches the palette before it has a session, and
 * refusing it would leave the login screen unstyled.
 */
export function withOptionalAuth<P = Record<string, string>>(
  fn: (request: Request, context: OptionalAuthContext<P>) => Promise<Response> | Response,
) {
  return handler<P>(async (request, context) => {
    const token = bearer(request);
    let auth: Auth | null = null;
    if (token) {
      try {
        auth = authFrom(token);
      } catch {
        // A stale token on a public route is not an error — the caller simply
        // gets the anonymous view.
      }
    }
    return fn(request, { ...context, auth });
  });
}

/**
 * Requires an administrator.
 *
 * **Re-reads the user document rather than trusting the `admin` claim alone.**
 * The claim is there so ordinary requests do not pay for a lookup; a route that
 * can repaint the app for every user is worth one read, and it is what makes a
 * revoked admin lose access immediately instead of at the next token refresh.
 */
export function withAdmin<P = Record<string, string>>(
  fn: (request: Request, context: AuthContext<P>) => Promise<Response> | Response,
) {
  return withAuth<P>(async (request, context) => {
    const users = await collections.users();
    const user = await users.findOne(
      { uid: context.auth.uid },
      { projection: { isAdmin: 1 } },
    );
    if (!user?.isAdmin) throw adminOnly();
    return fn(request, { ...context, auth: { ...context.auth, isAdmin: true } });
  });
}

/**
 * Requires a valid token *and* that a `:uid` path parameter names the caller.
 *
 * The only route that takes a uid from its path is `GET /profile/:uid`; every
 * other per-user query derives it from the token. This exists so that one route
 * cannot become a way to read a stranger's profile by changing a digit.
 */
export function withSelf<P extends { uid: string }>(
  fn: (request: Request, context: AuthContext<P>) => Promise<Response> | Response,
) {
  return withAuth<P>(async (request, context) => {
    const params = await context.params;
    if (params.uid !== context.auth.uid) {
      throw forbidden('That is not your account.');
    }
    return fn(request, context);
  });
}
