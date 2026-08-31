import { env } from '../config/env';
import { collections } from '../db/mongo';
import { tooManyRequests } from '../utils/errors';
import { log } from '../utils/logger';

/**
 * Per-IP request limits, counted in MongoDB.
 *
 * ## Why this could not be a port
 *
 * The Express server used `express-rate-limit` with its **default in-memory
 * store** across seven limiters, guarding login, registration, password reset,
 * OTP issue and verify, and the OAuth start and exchange. On one long-lived
 * process that is correct and costs nothing.
 *
 * On Vercel it is close to useless. Each serverless instance holds its own
 * counter, so a limit of "20 sign-in attempts per 15 minutes" becomes 20 × the
 * number of warm instances — a quantity nobody controls, that rises exactly when
 * traffic (or an attack) does. The limiter that guards `POST /auth/login` would
 * silently stop being the thing that makes bcrypt-per-guess expensive.
 *
 * So the counters live in the database, where every instance sees the same
 * number. This is not a novel design for this codebase: `otpSends` has always
 * been a database-backed rate limit, for exactly this reason, and this is the
 * same pattern generalised.
 *
 * ## The counting is a fixed window, deliberately
 *
 * One document per `(rule, client)` with a TTL, incremented on each request.
 * A sliding window would be more precise at the boundary — a burst spanning two
 * windows can reach 2× the limit — but it needs either a list of timestamps per
 * client or a second bucket, and both cost more per request than the imprecision
 * is worth here. These limits exist to make brute force expensive, not to meter
 * an API a customer is paying for.
 *
 * ## Failing open, and why
 *
 * If the database is unreachable the request is **allowed**. That is a real
 * trade-off and it goes this way round because the alternative is worse: a
 * transient Mongo blip would otherwise lock every user out of sign-in entirely,
 * turning a degraded dependency into a total outage. A failure here is logged
 * loudly; a failure that refuses all traffic is an incident.
 */

export interface RateLimitRule {
  /** Names the counter. Two routes sharing a name share a budget. */
  name: string;
  windowMs: number;
  /** Requests permitted per window, in production. */
  limit: number;
  /** Development allowance — high, so testing does not lock you out. */
  devLimit?: number;
  message?: string;
}

/**
 * The rules, mirroring the seven `express-rate-limit` instances one for one.
 *
 * The production numbers are unchanged from the Express server. The development
 * numbers are its 10× allowances, kept for the same reason: an afternoon of
 * testing sign-in should not lock the developer out of their own deployment.
 */
export const LIMITS = {
  /** `POST /auth/register`, `/auth/login`, `/auth/password/change`. */
  credentials: {
    name: 'credentials',
    windowMs: 15 * 60 * 1000,
    limit: 20,
    devLimit: 200,
    message: 'Too many attempts. Try again in a few minutes.',
  },
  /** `POST /auth/password/forgot`, `/auth/email/verify/send`. */
  reset: {
    name: 'reset',
    windowMs: 60 * 60 * 1000,
    limit: 5,
    devLimit: 100,
    message: 'Too many reset requests. Try again later.',
  },
  /** `POST /auth/phone/start`. */
  otpStart: {
    name: 'otp_start',
    windowMs: 15 * 60 * 1000,
    limit: 15,
    devLimit: 200,
    message: 'Too many requests. Try again in a few minutes.',
  },
  /** `POST /auth/phone/verify`, `/auth/phone/link`. */
  otpVerify: {
    name: 'otp_verify',
    windowMs: 15 * 60 * 1000,
    limit: 30,
    devLimit: 300,
    message: 'Too many attempts. Try again in a few minutes.',
  },
  /** `POST /auth/oauth/:provider/start`. */
  oauthStart: {
    name: 'oauth_start',
    windowMs: 15 * 60 * 1000,
    limit: 30,
    devLimit: 300,
    message: 'Too many sign-in attempts. Try again shortly.',
  },
  /** `POST /auth/oauth/exchange`. */
  oauthExchange: {
    name: 'oauth_exchange',
    windowMs: 15 * 60 * 1000,
    limit: 60,
    devLimit: 600,
    message: 'Too many attempts. Try again shortly.',
  },
  /** `POST /auth/link/code`, `/auth/link/confirm`. */
  link: {
    name: 'link',
    windowMs: 15 * 60 * 1000,
    limit: 20,
    devLimit: 200,
    message: 'Too many attempts. Try again in a few minutes.',
  },
} as const satisfies Record<string, RateLimitRule>;

/**
 * The caller's address.
 *
 * Vercel sets `x-forwarded-for`, and the **first** entry is the client — the
 * rest are proxies. This is the equivalent of Express's `trust proxy: 1`, and
 * getting it wrong in the other direction is what the old server's comment
 * warned about: keying on the proxy's address limits the whole world as one
 * client, which turns a per-IP limit into a global outage under load.
 *
 * `x-real-ip` is a fallback for other hosts. An unidentifiable caller is counted
 * under a shared bucket rather than exempted — being anonymous must not be a way
 * around the limit.
 */
export function clientAddress(request: Request): string {
  const forwarded = request.headers.get('x-forwarded-for');
  if (forwarded) {
    const first = forwarded.split(',')[0]?.trim();
    if (first) return first;
  }
  return request.headers.get('x-real-ip')?.trim() || 'unknown';
}

export interface RateLimitResult {
  allowed: boolean;
  limit: number;
  remaining: number;
  resetAt: Date;
}

/**
 * Counts one request against a rule and says whether it may proceed.
 *
 * The upsert is a single atomic operation: `$inc` creates the document at 1 when
 * it is absent, and `$setOnInsert` stamps the window's expiry. Two concurrent
 * requests therefore cannot both read 19 and both write 20 — which is precisely
 * the race a read-then-write implementation would lose.
 */
export async function consume(
  rule: RateLimitRule,
  clientId: string,
): Promise<RateLimitResult> {
  const limit = env.isProduction ? rule.limit : (rule.devLimit ?? rule.limit);
  const now = Date.now();

  // The window is part of the key, which is what makes this a fixed window with
  // no sweeping: the bucket for the next window is a different document, and the
  // TTL index removes the old one.
  const window = Math.floor(now / rule.windowMs);
  const bucket = `${rule.name}:${clientId}:${window}`;
  const resetAt = new Date((window + 1) * rule.windowMs);

  try {
    const rateLimits = await collections.rateLimits();
    const doc = await rateLimits.findOneAndUpdate(
      { bucket },
      {
        $inc: { hits: 1 },
        $setOnInsert: { createdAt: new Date(now), expiresAt: resetAt },
      },
      { upsert: true, returnDocument: 'after' },
    );

    const hits = doc?.hits ?? 1;
    return {
      allowed: hits <= limit,
      limit,
      remaining: Math.max(0, limit - hits),
      resetAt,
    };
  } catch (error) {
    // Fail open — see the note at the top of this file.
    log.error(`Rate limit check failed for ${rule.name}; allowing`, 'ratelimit', error);
    return { allowed: true, limit, remaining: limit, resetAt };
  }
}

/**
 * Enforces a rule, throwing [tooManyRequests] when it is exceeded.
 *
 * Returns the headers to attach to a successful response, in the `draft-7` form
 * the Express limiters advertised (`standardHeaders: 'draft-7'`), so a client
 * that reads them sees the same thing it did before.
 */
export async function enforce(
  rule: RateLimitRule,
  request: Request,
): Promise<Record<string, string>> {
  const result = await consume(rule, clientAddress(request));

  const headers: Record<string, string> = {
    'RateLimit-Limit': String(result.limit),
    'RateLimit-Remaining': String(result.remaining),
    'RateLimit-Reset': String(Math.max(0, Math.ceil((result.resetAt.getTime() - Date.now()) / 1000))),
  };

  if (!result.allowed) {
    const error = tooManyRequests(rule.message);
    // Carried so the handler wrapper can attach Retry-After.
    error.headers = {
      ...headers,
      'Retry-After': headers['RateLimit-Reset'] ?? '60',
    };
    throw error;
  }

  return headers;
}
