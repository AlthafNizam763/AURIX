import { NextResponse, type NextRequest } from 'next/server';

/**
 * CORS for the REST API.
 *
 * ## What this replaces
 *
 * `app.use(cors({ … }))` in `server/src/app.js`. Express applied it to every
 * route; Next.js has no equivalent hook inside a route handler, so it belongs in
 * middleware — which runs before the handler and can answer a preflight without
 * waking one.
 *
 * ## Who this is actually for
 *
 * **Not the mobile app.** CORS is a browser mechanism; a native Dart HTTP client
 * ignores it entirely, and an Android or iOS build would work perfectly with
 * none of this. It matters for exactly two callers:
 *
 *  * the **Flutter web build**, which runs in a browser at a different origin
 *    from the API and is refused by the browser without these headers; and
 *  * anything else browser-based that talks to the API from another origin.
 *
 * The admin portal needs none of it — it is same-origin with the API it calls.
 *
 * ## The allow-list, and what empty means
 *
 * `CORS_ORIGINS` is a comma-separated exact-match list. Empty **reflects
 * whatever origin asks**, which is right for local development against a
 * Flutter web build on a randomly-assigned port, and wrong in production. That
 * is the same behaviour the Express server had, and the same reason the admin
 * portal's Settings screen reports "Reflecting any origin" when it is unset.
 *
 * Note that reflecting is not the same as `Access-Control-Allow-Origin: *`.
 * The wildcard is what would actually be dangerous here, because it cannot be
 * combined with credentials and it hides which origin was served — so responses
 * become cacheable across origins. Echoing the request's own origin, with
 * `Vary: Origin`, keeps caches honest.
 *
 * ## Why no credentials
 *
 * `Access-Control-Allow-Credentials` is deliberately never sent. The API
 * authenticates with a bearer token in a header, not a cookie, so there are no
 * credentials for a browser to attach — and allowing them would turn the
 * reflect-any-origin development default into a genuine CSRF surface.
 *
 * The admin portal *does* use a cookie, and is unaffected: it is same-origin,
 * so no CORS decision is involved, and its cookie is `SameSite=Lax`.
 *
 * ## Runtime
 *
 * Edge, which is the default and is correct here: this reads `process.env` and
 * manipulates headers, and touches neither the database nor `jsonwebtoken`.
 * Keeping it off the Node runtime means a preflight costs no cold start.
 *
 * ## The portal's Content-Security-Policy also lives here
 *
 * It has to, and the reason is the bug this file was extended to fix. See
 * [portalCsp] below.
 */

const isProduction = process.env.NODE_ENV === 'production';

/** Parsed once per instance — the value cannot change without a redeploy. */
const ALLOWED = (process.env.CORS_ORIGINS ?? '')
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean);

/** Methods the API actually serves. */
const METHODS = 'GET,POST,PUT,PATCH,DELETE,OPTIONS';

/**
 * Headers a browser may send.
 *
 * `Authorization` is the one that matters — without it listed, every
 * authenticated cross-origin request fails its preflight, which is the failure
 * mode that looks like "the API is down" from a web build.
 */
const HEADERS = 'Authorization,Content-Type,Accept';

/** Headers a browser may *read* off the response. */
const EXPOSED = 'RateLimit-Limit,RateLimit-Remaining,RateLimit-Reset,Retry-After';

/** The origin to echo, or null when this request must not be granted one. */
function allowedOrigin(request: NextRequest): string | null {
  const origin = request.headers.get('origin');
  if (!origin) return null;
  if (ALLOWED.length === 0) return origin;
  return ALLOWED.includes(origin) ? origin : null;
}

function applyCors(response: NextResponse, origin: string | null): NextResponse {
  // Always, even when no origin is granted: the response varies by Origin
  // either way, and a cache that does not know that can serve one origin's
  // response to another.
  response.headers.set('Vary', 'Origin');

  if (!origin) return response;

  response.headers.set('Access-Control-Allow-Origin', origin);
  response.headers.set('Access-Control-Expose-Headers', EXPOSED);
  return response;
}

/**
 * The admin portal's Content-Security-Policy, bound to a single request.
 *
 * ## Why this moved out of `next.config.ts`
 *
 * It was a static header there, and it said `script-src 'self'` on the
 * reasoning that the React portal serves its JavaScript as files and therefore
 * needs no inline allowance. That reasoning was wrong, and wrong in a way that
 * broke the portal completely rather than partially.
 *
 * The App Router does not only ship files. It streams the React Server
 * Component payload — the props of every server-rendered element, and the
 * pointers to the client components that consume them — to the browser inside
 * **inline** `<script>` elements: `self.__next_f.push(...)`, one per chunk,
 * plus the bootstrap that starts hydration. A policy of `script-src 'self'`
 * blocks every one of them. The server renders correctly and returns 200, the
 * HTML arrives intact, and then the client has no payload to hydrate against
 * and swaps the whole page for Next's error boundary — "This page couldn't
 * load. A server error occurred." on a screen where nothing on the server had
 * gone wrong. The login form was the visible casualty.
 *
 * The fix is the mechanism CSP provides for exactly this: a nonce. It is
 * generated per request, sent in the policy, and read back by Next from the
 * `Content-Security-Policy` **request** header — which is how Next is told to
 * stamp the same nonce onto every script element it emits. A static header
 * cannot do this, because a value that does not change per response is not a
 * nonce.
 *
 * `'strict-dynamic'` accompanies it: scripts the nonced bootstrap loads inherit
 * its trust, which is what lets Next fetch its own chunks without the policy
 * having to enumerate them. Note that under `'strict-dynamic'` the `'self'`
 * source expression is ignored by browsers that understand it, and is kept only
 * for those that do not.
 *
 * `'unsafe-eval'` is allowed in development only — the React refresh transform
 * requires it — and is never sent in production.
 *
 * Styles keep `'unsafe-inline'`, unchanged and for the unchanged reason: Next
 * and Tailwind both inject inline `<style>` elements during hydration, and an
 * injected stylesheet can deface a page where an injected script can read a
 * session.
 */
function portalCsp(nonce: string): string {
  return [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isProduction ? '' : " 'unsafe-eval'"}`,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    "connect-src 'self'",
    "object-src 'none'",
    "frame-ancestors 'none'",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; ');
}

/**
 * A nonce for one response.
 *
 * `crypto.randomUUID` rather than a counter or a timestamp: a nonce an attacker
 * can predict is a nonce they can put on their own injected script, which
 * defeats the entire policy.
 */
function makeNonce(): string {
  return btoa(crypto.randomUUID());
}

/**
 * The portal, which needs a nonce, and nothing else.
 *
 * Every route under `/admin` is dynamically rendered — `force-dynamic` on the
 * login page and on the portal layout — which is the precondition for this: a
 * nonce can only be stamped into HTML generated per request, so a prerendered
 * page and a per-request nonce cannot both be right. The rest of the HTML
 * surface — `/`, which only redirects, and the 404 — is prerendered and keeps
 * the static policy in `next.config.ts`.
 */
function needsNonce(pathname: string): boolean {
  return pathname === '/admin' || pathname.startsWith('/admin/');
}

export function middleware(request: NextRequest): NextResponse {
  if (needsNonce(request.nextUrl.pathname)) {
    const nonce = makeNonce();
    const policy = portalCsp(nonce);

    // Both halves are required. The request header is what Next reads to find
    // the nonce and stamp onto the scripts it emits; the response header is
    // what the browser enforces. Sending one without the other produces either
    // scripts nobody polices or a policy no script can satisfy.
    const headers = new Headers(request.headers);
    headers.set('x-nonce', nonce);
    headers.set('Content-Security-Policy', policy);

    const response = NextResponse.next({ request: { headers } });
    response.headers.set('Content-Security-Policy', policy);
    return response;
  }

  const origin = allowedOrigin(request);

  // Preflight. Answered here rather than by a route handler, so it costs no
  // function invocation and no database connection.
  if (request.method === 'OPTIONS') {
    const preflight = new NextResponse(null, { status: 204 });
    if (origin) {
      preflight.headers.set('Access-Control-Allow-Methods', METHODS);
      preflight.headers.set('Access-Control-Allow-Headers', HEADERS);
      preflight.headers.set('Access-Control-Max-Age', '86400');
    }
    return applyCors(preflight, origin);
  }

  return applyCors(NextResponse.next(), origin);
}

/**
 * The API surface, plus the portal.
 *
 * `/health` is here for CORS — a browser-based monitor is a reasonable thing to
 * have, and it is JSON like everything else there. `/admin` is here for the
 * opposite reason: it is granted no CORS headers at all, because it is
 * same-origin by construction, and is matched only so that it can be given a
 * nonce. Static assets match neither.
 */
export const config = {
  matcher: ['/api/:path*', '/health', '/admin', '/admin/:path*'],
};
