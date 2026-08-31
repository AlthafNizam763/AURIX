import { ZodError } from 'zod';

import { env } from '../config/env';
import { ApiError, type ErrorBody, type ErrorDetail } from '../utils/errors';
import { log } from '../utils/logger';

/**
 * The single place a failure becomes a response.
 *
 * Ported from `server/src/middleware/error.js`. Express identified error
 * middleware by arity and ran it after the router; Next.js route handlers are
 * plain functions, so the equivalent is a wrapper each handler is passed
 * through — [handler] below.
 *
 * Two categories, treated very differently:
 *
 *  * **[ApiError]** — a failure the API meant to produce. Its code and message
 *    were written to be shown to a user, so both go out as-is.
 *  * **Everything else** — a bug, a driver error, a malformed body. The client
 *    gets `internal` and a generic sentence; the real message goes to the log.
 *    This is not politeness: a `MongoServerError` quotes the failing filter,
 *    which can contain another user's uid, and a `SyntaxError` from JSON parsing
 *    quotes the payload.
 */

/** 204, for the many writes that return nothing. */
export const noContent = (): Response => new Response(null, { status: 204 });

/**
 * A success body. Bare object, no envelope — see docs/MIGRATION_MAP.md §2.
 *
 * `headers` exists for the rate-limited routes, which advertise the caller's
 * remaining budget on success as well as on the 429.
 */
export const ok = <T extends object>(
  body: T,
  status = 200,
  headers?: Record<string, string>,
): Response => Response.json(body, { status, ...(headers ? { headers } : {}) });

export const created = <T extends object>(
  body: T,
  headers?: Record<string, string>,
): Response => ok(body, 201, headers);

function errorResponse(status: number, body: ErrorBody): Response {
  return Response.json(body, { status });
}

/** Turns any thrown value into the response the client expects. */
export function toErrorResponse(error: unknown, context: string): Response {
  if (error instanceof ApiError) {
    if (error.status >= 500) log.error(`${context} — ${error.message}`, 'http', error);
    // `headers` is set only by the rate limiter, which needs Retry-After and
    // the RateLimit-* family to reach the client on the 429 it throws.
    return Response.json(error.toJSON(), {
      status: error.status,
      ...(error.headers ? { headers: error.headers } : {}),
    });
  }

  // A schema failure. Express validated in middleware and never reached the
  // handler; here the handler parses and this catches what it throws, which
  // produces the identical body.
  if (error instanceof ZodError) {
    const details: ErrorDetail[] = error.issues.map((issue) => ({
      path: issue.path.join('.'),
      message: issue.message,
    }));
    return errorResponse(400, {
      error: {
        code: 'bad_request',
        message: 'That request was not in the expected shape.',
        details,
      },
    });
  }

  // A body that was not JSON. `req.json()` throws a SyntaxError where Express's
  // body parser produced `entity.parse.failed`.
  if (error instanceof SyntaxError) {
    return errorResponse(400, {
      error: { code: 'bad_request', message: 'That request body was not valid JSON.' },
    });
  }

  // A duplicate key means a unique index did its job — almost always a
  // concurrent create of a row that is meant to be unique. Surfacing it as a
  // conflict lets the client decide, rather than reading as a server fault.
  if ((error as { code?: number })?.code === 11000) {
    return errorResponse(409, {
      error: { code: 'conflict', message: 'That already exists.' },
    });
  }

  log.error(`Unhandled error on ${context}`, 'http', error);
  return errorResponse(500, {
    error: {
      code: 'internal',
      message: 'Something went wrong on our side.',
      ...(env.isProduction
        ? {}
        : { debug: String(error instanceof Error ? error.message : error) }),
    },
  } as ErrorBody);
}

/** The route-handler context Next passes as the second argument. */
export interface RouteContext<P = Record<string, string>> {
  params: Promise<P>;
}

export type Handler<P = Record<string, string>> = (
  request: Request,
  context: RouteContext<P>,
) => Promise<Response> | Response;

/**
 * Wraps a route handler so no thrown value escapes as an unshaped 500.
 *
 * Every route is exported through this. It is the replacement for Express's
 * `route()` helper *and* its error middleware, which were two things there and
 * are one thing here because a Next handler has nowhere else to put them.
 */
export function handler<P = Record<string, string>>(fn: Handler<P>): Handler<P> {
  return async (request, context) => {
    try {
      return await fn(request, context);
    } catch (error) {
      const url = new URL(request.url);
      return toErrorResponse(error, `${request.method} ${url.pathname}`);
    }
  };
}
