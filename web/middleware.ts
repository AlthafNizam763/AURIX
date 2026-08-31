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
 */

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

export function middleware(request: NextRequest): NextResponse {
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
 * The API surface only.
 *
 * `/health` is included — a browser-based monitor is a reasonable thing to
 * have, and it is JSON like everything else here. The portal and its assets are
 * excluded because they are same-origin by construction, and adding CORS
 * headers to an HTML page grants nothing and invites confusion.
 */
export const config = {
  matcher: ['/api/:path*', '/health'],
};
