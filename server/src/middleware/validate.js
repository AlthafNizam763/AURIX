import { z } from 'zod';

import { badRequest } from '../utils/errors.js';

/**
 * Schema validation for request bodies, queries and path parameters.
 *
 * Every write route validates. This is not ceremony: the client is now the only
 * thing between a user and the database, and the client is code an attacker
 * controls. A track row with a 40MB `title`, a `position` of `NaN` or an
 * `artists` array of ten thousand entries all have to be refused here, because
 * `firestore.rules` — which used to assert document *shape* on every write — is
 * gone and this is what replaced it.
 *
 * The schemas below are deliberately close to the Firestore rules they descend
 * from: the same fields, the same length caps, the same "this field may only be
 * one of these values" constraints.
 */
export function validate({ body, query, params }) {
  return (req, _res, next) => {
    try {
      if (body) req.body = body.parse(req.body ?? {});
      if (query) {
        // Express 5 exposes `req.query` as a getter with no setter, so the
        // parsed result goes to a sibling property rather than overwriting it.
        req.valid = { ...(req.valid ?? {}), query: query.parse(req.query ?? {}) };
      }
      if (params) req.params = params.parse(req.params ?? {});
      return next();
    } catch (error) {
      if (error instanceof z.ZodError) {
        return next(
          badRequest(
            'That request was not in the expected shape.',
            error.issues.map((issue) => ({
              path: issue.path.join('.'),
              message: issue.message,
            })),
          ),
        );
      }
      return next(error);
    }
  };
}

/** `req.valid.query` with a fallback, so handlers can read it unconditionally. */
export const q = (req) => req.valid?.query ?? {};

// ---------------------------------------------------------------------------
// Shared field schemas
// ---------------------------------------------------------------------------

export const S = {
  email: z
    .string()
    .trim()
    .min(3)
    .max(320)
    .email('That does not look like an email address.')
    .transform((value) => value.toLowerCase()),

  // Eight, where Firebase Auth enforced six. Raised because there are no
  // existing accounts to grandfather — nothing carries over from Firebase — so
  // this is the one moment the floor can move without locking anyone out.
  //
  // **Must match `AppConstants.minPasswordLength` in the Flutter app.** The two
  // are separate checks doing separate jobs: the client's is instant feedback
  // in a form, this one actually decides. They only work together if they
  // agree, and a client minimum *below* this one is the bad direction — the
  // form accepts the password and the request is then refused.
  password: z.string().min(8, 'Use at least 8 characters.').max(200),

  displayName: z.string().trim().min(1).max(80),

  uid: z.string().trim().min(1).max(64),

  /** Document ids the client derives — TrackKey, SongKey, PlaylistKey. */
  docId: z
    .string()
    .trim()
    .min(1)
    .max(220)
    .regex(/^[A-Za-z0-9._~-]+$/, 'That id contains characters an id may not contain.'),

  url: z.string().trim().max(2048),

  /**
   * A track row, in the flat shape `Track.toDocument()` produces.
   *
   * Passthrough is deliberately *not* used: an unknown field is dropped rather
   * than stored, so a compromised client cannot append arbitrary data to
   * another user's library document.
   */
  track: z
    .object({
      title: z.string().max(500).default('Unknown track'),
      artist: z.string().max(500).default(''),
      album: z.string().max(500).default(''),
      durationMs: z.number().int().min(0).max(24 * 60 * 60 * 1000).default(0),
      artworkUrl: z.string().max(2048).default(''),
      explicit: z.boolean().default(false),
      source: z.string().max(32).default('aurix'),
      sourceId: z.string().max(220).nullish(),
      spotifyId: z.string().max(220).nullish(),
      youtubeVideoId: z.string().max(220).nullish(),
      previewUrl: z.string().max(2048).nullish(),
    })
    .strip(),
};

export { z };
