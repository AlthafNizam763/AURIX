import type { IndexDescription } from 'mongodb';

/**
 * The shape of AURIX's MongoDB database, in one place.
 *
 * Ported from `server/src/db/collections.js`, which in turn replaced
 * `firestore_paths.dart`. It exists for the same reason both of those did: a
 * collection name typed at a call site is a name nobody checked against the
 * indexes, and the failure mode is a silent collection scan or a write into a
 * collection no query reads.
 *
 * ## The layout
 *
 * Firestore's nesting (`/users/{uid}/playlists/{id}/tracks/{trackId}`) did not
 * survive the move to Mongo, and should not have: Mongo has no subcollections,
 * and modelling them as embedded arrays would break the two things the nesting
 * was buying. The hierarchy moved from the *path* into *indexed fields*:
 *
 * ```
 * users                    { uid, email?, phone?, passwordHash?, name, avatarId, isAdmin }
 * identities               { uid, provider, subject, email }        unique (provider, subject)
 * refreshTokens            { tokenHash, uid, expiresAt }            TTL
 * actionTokens             { tokenHash, uid, kind, expiresAt }      TTL
 * otpCodes                 { destination, purpose, codeHash, attempts, expiresAt }  TTL
 * otpSends                 { destination, createdAt, expiresAt }    TTL
 * authStates               { state, provider, intent, expiresAt }   TTL
 * authGrants               { codeHash, kind, payload, expiresAt }   TTL
 * rateLimits               { bucket, hits, expiresAt }              TTL   (new — see below)
 *
 * likedTracks              { uid, trackId, ...track }               unique (uid, trackId)
 * recentlyPlayed           { uid, itemId, ...entry, playedAt }      unique (uid, itemId)
 * userPlaylists            { uid, playlistId, ...playlist }         unique (uid, playlistId)
 * userPlaylistTracks       { uid, playlistId, trackId, position }   unique (uid, playlistId, trackId)
 *
 * catalogSongs             { _id: songId, ...song, searchTokens[] } shared, global
 * globalPlaylists          { _id: playlistId, ..., importedByUserId } shared, global
 * globalPlaylistTracks     { playlistId, trackId, position }        unique (playlistId, trackId)
 *
 * appConfig                { _id: 'theme', ... }                    singleton documents
 * brandAssets.files/.chunks                                          GridFS
 * ```
 *
 * ## Why the two shared collections sit apart from the per-user ones
 *
 * `catalogSongs` and `globalPlaylists` are *shared*: they are what make an
 * import a contribution to AURIX rather than a private copy. A song imported by
 * one user is findable in global search by every user, and a playlist imported
 * by one user can be opened and played by another. Neither carries a `uid`
 * filter on read.
 *
 * Provenance is therefore recorded in fields — `importedByUserId`, `importedBy`,
 * `importedAt` — and *not one of them narrows who may read*. Only the delete
 * route consults `importedByUserId`. That distinction — recorded, not enforcing
 * — is the whole design.
 *
 * ## Where the security boundary is
 *
 * The client cannot reach the database at all. Every write goes through a route
 * handler that has already resolved the caller's uid from a signed token, and a
 * per-user collection is only ever queried with that uid spliced in by the
 * handler — never by a uid taken from the request body. What used to be a
 * Firestore rule a client could try to talk past is now a query the client
 * cannot phrase.
 */

export const COLLECTIONS = {
  users: 'users',
  refreshTokens: 'refreshTokens',
  actionTokens: 'actionTokens',

  // ---- Multi-method sign-in ---------------------------------------------
  //
  // `identities` is the table that makes "Continue with Google" and "Continue
  // with Apple" land on *one* account. It is deliberately a collection rather
  // than an array on the user document, because the query that matters runs the
  // other way round: sign-in starts from a provider and a subject and has to
  // find the uid, and a unique index on `(provider, subject)` is what makes
  // that both fast and *exclusive* — the same Google account cannot be attached
  // to two AURIX users, because the index refuses the second write.
  identities: 'identities',

  // Live one-time codes, one per (destination, purpose). Hashed, TTL'd, and
  // carrying their own attempt counter.
  otpCodes: 'otpCodes',
  // A row per code *sent*, expiring after an hour. Counting rows is the
  // per-destination send limit; separate from the per-IP limiter because the
  // two defend against different things.
  otpSends: 'otpSends',

  // A browser OAuth round trip in progress: the `state` the provider will echo
  // back, which app redirect it belongs to, and the PKCE verifier.
  authStates: 'authStates',
  // What the app redeems once the browser comes home — either a session or a
  // pending account link. Never a provider token.
  authGrants: 'authGrants',

  /**
   * Per-IP request counters. **New in the Next.js port.**
   *
   * The Express app used `express-rate-limit` with its default in-memory store,
   * which counts within one process. Serverless has many processes, so an
   * in-memory limiter would let the effective limit multiply by however many
   * instances happen to be warm — a login limit of 20 becomes 20 × N, which is
   * not a limit. The counters therefore live in the database, where every
   * instance sees the same number.
   *
   * The pattern is not new to this codebase: `otpSends` has always been a
   * database-backed rate limit, for the same reason.
   */
  rateLimits: 'rateLimits',

  likedTracks: 'likedTracks',
  recentlyPlayed: 'recentlyPlayed',
  userPlaylists: 'userPlaylists',
  userPlaylistTracks: 'userPlaylistTracks',

  catalogSongs: 'catalogSongs',
  globalPlaylists: 'globalPlaylists',
  globalPlaylistTracks: 'globalPlaylistTracks',

  appConfig: 'appConfig',
} as const;

export type CollectionKey = keyof typeof COLLECTIONS;

export const GRIDFS_BUCKET = 'brandAssets';

/** The `_id` of the singleton theme document in `appConfig`. */
export const THEME_DOC_ID = 'theme';

/**
 * Field names that appear in queries, spelled once.
 *
 * A typo in a Mongo filter is the silent kind of bug: a field that does not
 * exist matches nothing rather than raising, so a mistyped search key returns an
 * empty page and looks like it worked.
 */
export const FIELDS = {
  uid: 'uid',
  createdAt: 'createdAt',
  updatedAt: 'updatedAt',
  playedAt: 'playedAt',
  position: 'position',
  trackCount: 'trackCount',
  source: 'source',
  sourceId: 'sourceId',
  sourceUrl: 'sourceUrl',
  name: 'name',
  searchTokens: 'searchTokens',
  searchTitle: 'searchTitle',
  syncedAt: 'syncedAt',
  importedByUserId: 'importedByUserId',
  importedBy: 'importedBy',
  importedAt: 'importedAt',
} as const;

/**
 * Index definitions, keyed by the same names as [COLLECTIONS].
 *
 * Two categories:
 *
 *  * **Unique constraints are the schema.** `(uid, trackId)` on liked tracks is
 *    what makes liking a song twice idempotent — the property Firestore got
 *    from deriving the document id from `TrackKey`. Without it, the upsert in
 *    the like route would race itself and produce duplicate rows.
 *  * **Query indexes** back a specific query. Every one below is used; the sort
 *    direction matters, because a compound index only serves a sort whose keys
 *    are a prefix of it in a compatible order.
 *
 * The TTL indexes on the token collections are load-bearing rather than
 * housekeeping: expired refresh tokens are what an attacker with an old backup
 * would replay, and letting Mongo delete them is more reliable than a cron —
 * which matters more here than it did on the old server, because serverless has
 * nowhere to run a cron.
 */
export const INDEXES: Record<CollectionKey, IndexDescription[]> = {
  users: [
    { key: { uid: 1 }, name: 'uid_unique', unique: true },
    // Case-insensitive uniqueness. Emails are lowercased on write as well —
    // belt and braces, because the collation only helps queries that ask for
    // it, and a stray driver call that forgets would otherwise let "A@x.com"
    // and "a@x.com" both register.
    //
    // **Sparse**, since phone sign-in arrived. An account created from a phone
    // number has no email address at all, and a non-sparse unique index would
    // let exactly one such account exist — the second would collide on the
    // missing field. `createUser` therefore omits `email` entirely rather than
    // writing null or '', which is what keeps this index honest.
    {
      key: { email: 1 },
      name: 'email_unique',
      unique: true,
      sparse: true,
      collation: { locale: 'en', strength: 2 },
    },
    // Same reasoning, other direction: an email account has no phone. Stored in
    // E.164, which is what makes "+44 7700 900123" and "+447700900123" the same
    // row.
    { key: { phone: 1 }, name: 'phone_unique', unique: true, sparse: true },
  ],

  identities: [
    // The constraint the whole linking design rests on: one provider account
    // belongs to at most one AURIX user. Two people cannot claim the same
    // Google subject, and a link attempt that would do so fails here rather
    // than in a race between two reads.
    { key: { provider: 1, subject: 1 }, name: 'provider_subject_unique', unique: true },
    { key: { uid: 1 }, name: 'uid' },
    // Backs the "does a verified provider email already belong to someone?"
    // lookup that decides between creating an account and challenging for a
    // link. Sparse because Apple private-relay accounts may carry none.
    { key: { email: 1 }, name: 'email', sparse: true },
  ],

  otpCodes: [
    // One live code per destination and purpose. Requesting a second burns the
    // first, so an SMS forwarded or read off a lock screen earlier stops
    // working — the same rule action tokens follow.
    { key: { destination: 1, purpose: 1 }, name: 'destination_purpose_unique', unique: true },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  otpSends: [
    { key: { destination: 1, createdAt: -1 }, name: 'destination_createdAt' },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  authStates: [
    { key: { state: 1 }, name: 'state_unique', unique: true },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  authGrants: [
    { key: { codeHash: 1 }, name: 'codeHash_unique', unique: true },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  rateLimits: [
    { key: { bucket: 1 }, name: 'bucket_unique', unique: true },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  refreshTokens: [
    { key: { tokenHash: 1 }, name: 'tokenHash_unique', unique: true },
    { key: { uid: 1 }, name: 'uid' },
    // Mongo's TTL monitor deletes these within ~60s of expiry.
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  actionTokens: [
    { key: { tokenHash: 1 }, name: 'tokenHash_unique', unique: true },
    { key: { uid: 1, kind: 1 }, name: 'uid_kind' },
    { key: { expiresAt: 1 }, name: 'ttl', expireAfterSeconds: 0 },
  ],

  likedTracks: [
    { key: { uid: 1, trackId: 1 }, name: 'uid_track_unique', unique: true },
    // Backs `GET /library/liked` — newest first, which is the order the Liked
    // Songs screen has always shown.
    { key: { uid: 1, createdAt: -1 }, name: 'uid_createdAt' },
  ],

  recentlyPlayed: [
    { key: { uid: 1, itemId: 1 }, name: 'uid_item_unique', unique: true },
    { key: { uid: 1, playedAt: -1 }, name: 'uid_playedAt' },
  ],

  userPlaylists: [
    { key: { uid: 1, playlistId: 1 }, name: 'uid_playlist_unique', unique: true },
    { key: { uid: 1, updatedAt: -1 }, name: 'uid_updatedAt' },
    // Backs `findOwnBySource` — the duplicate-import check.
    { key: { uid: 1, source: 1, sourceId: 1 }, name: 'uid_source' },
  ],

  userPlaylistTracks: [
    {
      key: { uid: 1, playlistId: 1, trackId: 1 },
      name: 'uid_playlist_track_unique',
      unique: true,
    },
    // The playlist's own order. `position` is a double, not an int — that is
    // what makes a drag a single write instead of a renumber.
    { key: { uid: 1, playlistId: 1, position: 1 }, name: 'uid_playlist_position' },
  ],

  catalogSongs: [
    // Firestore's `array-contains` became a plain equality match on an array
    // field, which a standard index serves. This is the whole of global song
    // search.
    { key: { searchTokens: 1 }, name: 'searchTokens' },
    { key: { spotifyId: 1 }, name: 'spotifyId', sparse: true },
    { key: { youtubeVideoId: 1 }, name: 'youtubeVideoId', sparse: true },
    { key: { updatedAt: -1 }, name: 'updatedAt' },
  ],

  globalPlaylists: [
    { key: { searchTokens: 1 }, name: 'searchTokens' },
    { key: { searchTitle: 1 }, name: 'searchTitle' },
    { key: { source: 1, sourceId: 1 }, name: 'source_sourceId' },
    { key: { sourceUrl: 1 }, name: 'sourceUrl', sparse: true },
    // Backs "playlists I imported" on the Library screen. The only query in the
    // app that filters the shared catalogue by a uid, and it is a
    // *presentation* filter, not an access-control one.
    { key: { importedByUserId: 1, importedAt: -1 }, name: 'importedBy' },
    { key: { updatedAt: -1 }, name: 'updatedAt' },
  ],

  globalPlaylistTracks: [
    { key: { playlistId: 1, trackId: 1 }, name: 'playlist_track_unique', unique: true },
    { key: { playlistId: 1, position: 1 }, name: 'playlist_position' },
  ],

  appConfig: [],
};
