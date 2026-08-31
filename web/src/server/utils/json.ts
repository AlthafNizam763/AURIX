/**
 * Wire-format helpers shared by every route.
 *
 * Ported from the parts of `server/src/utils/async.js` that survive: the
 * Express-specific `route()` wrapper does not — Next.js route handlers are
 * plain async functions and a rejected promise is already the framework's
 * problem — but the response shaping is identical and the Dart client depends
 * on it being so.
 */

/**
 * ISO-8601, which is what every timestamp crosses the wire as.
 *
 * Matches `Json.timestamp` on the Dart side. Anything not a `Date` passes
 * through, so a value already serialised upstream is not mangled by being
 * handled twice.
 */
export function iso(value: unknown): string | null {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === 'string') return value;
  return null;
}

/** Clamps a `limit` query parameter into a sane range. */
export function limitOf(
  raw: string | null | undefined,
  { fallback = 50, max = 500 }: { fallback?: number; max?: number } = {},
): number {
  const parsed = Number.parseInt(raw ?? '', 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(parsed, max);
}
