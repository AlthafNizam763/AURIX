import type { ObjectId } from 'mongodb';

/**
 * The stored shape of every collection.
 *
 * Written now rather than in Phase 4 because these are only honest once the
 * services that own them have been read end to end: a document type guessed
 * from a handler's read path misses the fields only its write path sets, and a
 * type that is confidently wrong is worse than one that is loose.
 *
 * ## Optional means genuinely absent, not empty
 *
 * `email` and `phone` on [UserDoc] are optional in the strong sense: the field
 * is **omitted from the document**, not stored as `''` or `null`. Both are
 * backed by *sparse* unique indexes, which skip documents missing the field but
 * index `''` and `null` like any other value — so writing an empty string would
 * permit exactly one phone-only account and reject the second with a duplicate
 * key. `createUser` omits them, and these types are marked to match.
 */

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

export interface UserDoc {
  /**
   * The primary key — deliberately not `_id`.
   *
   * Every per-user collection keys on this, it appears in the app's own models
   * (`AurixUser.uid`), in rows cached on the device, and in `importedByUserId`
   * on shared playlists. Keeping it an opaque server-allocated string is what
   * let all of those keep their shape when identity moved off Firebase.
   */
  uid: string;
  name: string;
  /** Absent, never empty — see the note above. Lowercased on write. */
  email?: string;
  /** Absent, never empty. E.164. */
  phone?: string;
  /** Absent for accounts created by a social provider or a phone code. */
  passwordHash?: string;
  avatarId: string;
  emailVerified: boolean;
  phoneVerified: boolean;
  /** Apple's per-application forwarding address. Deliverable, but not "their" email. */
  emailIsPrivateRelay?: boolean;
  isAdmin: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export type ProviderId = 'google' | 'apple' | 'facebook' | 'github';

/** Sign-in methods that live on the user document rather than in `identities`. */
export type LocalProvider = 'password' | 'phone';

export type SignInMethod = LocalProvider | ProviderId;

export interface IdentityDoc {
  uid: string;
  provider: ProviderId;
  /** The provider's own immutable id. The identity — *not* the email. */
  subject: string;
  email?: string;
  emailVerified: boolean;
  isPrivateRelay: boolean;
  displayName: string;
  avatarUrl: string;
  createdAt: Date;
  updatedAt: Date;
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

/** Only the SHA-256 is stored: a leaked backup must not yield live sessions. */
export interface RefreshTokenDoc {
  tokenHash: string;
  uid: string;
  device: string | null;
  createdAt: Date;
  expiresAt: Date;
}

export type ActionKind = 'reset_password' | 'verify_email';

export interface ActionTokenDoc {
  tokenHash: string;
  uid: string;
  kind: ActionKind;
  createdAt: Date;
  expiresAt: Date;
}

// ---------------------------------------------------------------------------
// One-time codes
// ---------------------------------------------------------------------------

export type OtpPurpose = 'sign_in' | 'link_phone' | 'link_account';

export interface OtpCodeDoc {
  _id?: ObjectId;
  /** Opaque: a phone number for sign-in, an email for an account link. */
  destination: string;
  purpose: OtpPurpose;
  /** SHA-256 digest, stored as BSON binary. */
  codeHash: Buffer;
  attempts: number;
  createdAt: Date;
  expiresAt: Date;
}

/**
 * A row per code *sent*.
 *
 * Counting rows is the per-destination hourly limit. Deliberately separate from
 * the attempt counter on [OtpCodeDoc], which is destroyed on every successful
 * verification — a counter there would reset itself for free.
 */
export interface OtpSendDoc {
  destination: string;
  createdAt: Date;
  expiresAt: Date;
}

// ---------------------------------------------------------------------------
// OAuth
// ---------------------------------------------------------------------------

export type AuthIntent = 'signIn' | 'link';

/** A browser round trip in flight. Deleted the moment the callback is handled. */
export interface AuthStateDoc {
  state: string;
  provider: ProviderId;
  intent: AuthIntent;
  /** The account being linked to, when `intent` is `link`. Decided at start. */
  uid: string | null;
  /** Where this flow is allowed to finish. Checked against the allow-list. */
  redirectUri: string;
  verifier: string;
  nonce: string;
  device: string | null;
  createdAt: Date;
  expiresAt: Date;
}

export interface SocialProfile {
  subject: string;
  email: string;
  emailVerified: boolean;
  isPrivateRelay?: boolean;
  name: string;
  avatarUrl: string;
}

export type GrantKind = 'session' | 'link';

export interface GrantPayload {
  profile?: SocialProfile;
  device?: string | null;
  created?: boolean;
  linked?: boolean;
}

/**
 * What the app redeems after the browser comes home.
 *
 * A `session` grant is consumed on first use. A `link` grant survives being
 * read, because the account-link challenge is a conversation — send a code,
 * then confirm it — and carries `attempts` so it cannot become an unmetered
 * password oracle for the account it names.
 */
export interface AuthGrantDoc {
  _id?: ObjectId;
  codeHash: string;
  kind: GrantKind;
  provider: ProviderId;
  uid: string | null;
  payload: GrantPayload;
  attempts: number;
  createdAt: Date;
  expiresAt: Date;
}

// ---------------------------------------------------------------------------
// The shared catalogue
// ---------------------------------------------------------------------------

/**
 * A song in the shared catalogue.
 *
 * **`_id` is a string, not an `ObjectId`** — and declaring that is not a
 * formality. The id is derived on the client from the track itself (`SongKey`),
 * which is what makes two people importing the same song converge on one
 * document rather than creating two. The driver's default `_id` type is
 * `ObjectId`, so without this every query against the collection is a type
 * error, and — more to the point — a `new ObjectId(...)` slipped in anywhere
 * would silently stop matching anything.
 */
export interface CatalogSongDoc {
  _id: string;
  title: string;
  artists: string[];
  album: string;
  duration: number;
  artworkUrl: string;
  source: string;
  sourceId: string;
  externalUrl: string;
  explicit: boolean;
  searchTokens: string[];
  spotifyId?: string;
  youtubeVideoId?: string;
  previewUrl?: string;
  createdAt: Date;
  updatedAt: Date;
}

/** A playlist in the shared catalogue. `_id` is client-derived, as above. */
export interface GlobalPlaylistDoc {
  _id: string;
  name: string;
  searchTitle: string;
  searchTokens: string[];
  description: string;
  coverUrl: string;
  source: string;
  sourceId: string;
  sourceUrl: string;
  trackCount: number;
  /** Provenance, not ownership. Enforces only on delete. */
  importedByUserId: string;
  importedBy: string;
  importedAt: Date;
  createdAt: Date;
  updatedAt: Date;
  syncedAt?: Date;
}

/** The singleton documents in `appConfig`. `_id` is a name, e.g. `'theme'`. */
export interface AppConfigDoc {
  _id: string;
  [key: string]: unknown;
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

/**
 * One counter per (route, client) pair, expiring with its window.
 *
 * New in the Next.js port: `express-rate-limit`'s in-memory store counted
 * within one process, which on serverless means one count per warm instance.
 */
export interface RateLimitDoc {
  bucket: string;
  hits: number;
  createdAt: Date;
  expiresAt: Date;
}
