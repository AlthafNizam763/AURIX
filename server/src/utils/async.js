/**
 * Wraps an async route handler so a rejected promise reaches the error
 * middleware.
 *
 * Express 5 forwards rejections from async handlers on its own, so this is
 * belt-and-braces rather than strictly required — but it also documents intent
 * at every call site, and it keeps the handlers working unchanged if the app is
 * ever mounted under an Express 4 router (which does *not* forward them, and
 * fails by hanging the request rather than by erroring).
 */
export const route = (handler) => (req, res, next) =>
  Promise.resolve(handler(req, res, next)).catch(next);

/** ISO-8601, which is what every timestamp crosses the wire as. See `Json.timestamp`. */
export const iso = (date) => (date instanceof Date ? date.toISOString() : date ?? null);

/** Clamps a `limit` query parameter into a sane range. */
export function limitOf(raw, { fallback = 50, max = 500 } = {}) {
  const parsed = Number.parseInt(raw ?? '', 10);
  if (!Number.isFinite(parsed) || parsed <= 0) return fallback;
  return Math.min(parsed, max);
}
