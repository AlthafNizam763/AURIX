import { z } from 'zod';

/**
 * Schema validation for request bodies, queries and path parameters.
 *
 * Every write route validates. This is not ceremony: the client is the only
 * thing between a user and the database, and the client is code an attacker
 * controls. A track row with a 40MB `title`, a `position` of `NaN` or an
 * `artists` array of ten thousand entries all have to be refused here, because
 * `firestore.rules` — which used to assert document *shape* on every write — is
 * gone and this is what replaced it.
 *
 * The schemas below are deliberately close to the Firestore rules they descend
 * from: the same fields, the same length caps, the same "this field may only be
 * one of these values" constraints.
 *
 * ## What changed from Express
 *
 * There, `validate({ body, query, params })` was middleware that parsed before
 * the handler ran and stashed the result on `req`. Here the handler parses
 * directly and a `ZodError` is caught by the response wrapper, which produces
 * the identical `bad_request` body with the identical `details` array. One less
 * indirection, and the parsed value is properly typed at the call site instead
 * of being cast off `req.valid`.
 */

/** Reads and parses a JSON body. An absent body parses as `{}`, as Express did. */
export async function body<T extends z.ZodType>(request: Request, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    const text = await request.text();
    raw = text.length > 0 ? JSON.parse(text) : {};
  } catch {
    // Rethrown as a SyntaxError so the response wrapper reports
    // "That request body was not valid JSON" rather than a schema failure.
    throw new SyntaxError('Invalid JSON body');
  }
  return schema.parse(raw ?? {});
}

/** Parses the query string. */
export function query<T extends z.ZodType>(request: Request, schema: T): z.infer<T> {
  const params = new URL(request.url).searchParams;
  return schema.parse(Object.fromEntries(params.entries()));
}

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

  /**
   * Eight characters, where Firebase Auth enforced six.
   *
   * **Must match `AppConstants.minPasswordLength` in the Flutter app.** The two
   * are separate checks doing separate jobs: the client's is instant feedback in
   * a form, this one actually decides. They only work together if they agree,
   * and a client minimum *below* this one is the bad direction — the form
   * accepts the password and the request is then refused.
   */
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
   * `.strip()` is deliberate and is not the default's equivalent: an unknown
   * field is **dropped rather than stored**, so a compromised client cannot
   * append arbitrary data to another user's library document.
   */
  track: z
    .object({
      title: z.string().max(500).default('Unknown track'),
      artist: z.string().max(500).default(''),
      album: z.string().max(500).default(''),
      durationMs: z
        .number()
        .int()
        .min(0)
        .max(24 * 60 * 60 * 1000)
        .default(0),
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

/** `{ trackId, track }` — the pair every playlist write submits. */
export const trackEntry = z.object({ trackId: S.docId, track: S.track });

/** An optional device label, carried on every route that mints a session. */
export const deviceField = z.string().max(120).optional();

export { z };
