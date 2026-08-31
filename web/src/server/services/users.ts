import crypto from 'node:crypto';

import bcrypt from 'bcryptjs';

import { env } from '../config/env';
import { collections } from '../db/mongo';
import type { LocalProvider, SignInMethod, UserDoc } from '../db/documents';
import { emailInUse, notFound, phoneInUse } from '../utils/errors';
import { iso } from '../utils/json';

/**
 * The user record — AURIX's identity.
 *
 * ## `uid` is the primary key, not `_id`
 *
 * Every per-user collection keys on `uid`, and that indirection is worth
 * keeping rather than collapsing onto Mongo's `ObjectId`: the uid appears in
 * the app's own models (`AurixUser.uid`), in cached rows on the device, and in
 * `importedByUserId` on shared playlists. Making it an opaque string the server
 * allocates means none of those had to change shape when identity moved off
 * Firebase, and it leaves room for a future identity provider to supply one.
 *
 * ## Password storage
 *
 * bcrypt at cost 12. **The hash never leaves this module** — [publicUser] exists
 * so that no route can accidentally serialise a user document straight to a
 * response, which is exactly how password hashes get published.
 */

const BCRYPT_ROUNDS = 12;

/** The account as a client is allowed to see it. Mirrors `AurixUser` in Dart. */
export interface PublicUser {
  uid: string;
  name: string;
  email: string;
  phone: string;
  avatarId: string;
  emailVerified: boolean;
  phoneVerified: boolean;
  emailIsPrivateRelay: boolean;
  isAdmin: boolean;
  providers: SignInMethod[];
  createdAt: string | null;
  updatedAt: string | null;
}

/** A uid with the same shape and entropy budget Firebase Auth used. */
export function newUid(): string {
  return crypto.randomBytes(14).toString('base64url').slice(0, 28);
}

export const hashPassword = (password: string): Promise<string> =>
  bcrypt.hash(password, BCRYPT_ROUNDS);

/**
 * Compares a password with a stored hash.
 *
 * Answers `false` for a missing hash rather than throwing, and that is
 * load-bearing in two places: an account created by a social provider or a
 * phone code genuinely has no password, so no password is correct; and the
 * login route relies on being able to call this with `user?.passwordHash ?? ''`
 * for an account that does not exist, so that the bcrypt cost is paid either
 * way and response timing does not disclose which addresses are registered.
 */
export const verifyPassword = (password: string, hash: string | undefined): Promise<boolean> =>
  typeof hash === 'string' && hash.length > 0
    ? bcrypt.compare(password, hash)
    : Promise.resolve(false);

/**
 * The only shape a user is ever sent to a client in.
 *
 * Timestamps are ISO-8601 strings, which `Json.timestamp` on the Dart side
 * already parses — that is why the model needed no change when Firestore's
 * `Timestamp` went away.
 */
export function publicUser(
  doc: UserDoc | null | undefined,
  { providers }: { providers?: SignInMethod[] } = {},
): PublicUser | null {
  if (!doc) return null;
  return {
    uid: doc.uid,
    name: doc.name ?? '',
    email: doc.email ?? '',
    phone: doc.phone ?? '',
    avatarId: doc.avatarId ?? 'avatar_01',
    emailVerified: doc.emailVerified === true,
    phoneVerified: doc.phoneVerified === true,
    // Apple's private relay. A real, deliverable address, but one Apple minted
    // for this application alone — so it is not the user's email in any sense
    // they would recognise, and a profile screen that renders it without saying
    // so looks broken.
    emailIsPrivateRelay: doc.emailIsPrivateRelay === true,
    isAdmin: doc.isAdmin === true,
    // Which ways in this account has. Present so Settings can show what is
    // linked and refuse to unlink the last one, and so the sign-in screen can
    // say "you usually continue with Google" during an account link.
    providers: providers ?? localProviders(doc),
    createdAt: iso(doc.createdAt),
    updatedAt: iso(doc.updatedAt),
  };
}

/** The sign-in methods recorded on the user document, with no second read. */
export function localProviders(doc: UserDoc | null | undefined): LocalProvider[] {
  const out: LocalProvider[] = [];
  if (typeof doc?.passwordHash === 'string' && doc.passwordHash.length > 0) {
    out.push('password');
  }
  if (doc?.phone) out.push('phone');
  return out;
}

/**
 * Every way into an account, including the linked social identities.
 *
 * One extra query, on routes that run once per sign-in or once per profile
 * read. [accountViews] is the batched form, for the admin user list.
 */
export async function providersFor(user: UserDoc | null | undefined): Promise<SignInMethod[]> {
  if (!user) return [];
  const identities = await collections.identities();
  const rows = await identities
    .find({ uid: user.uid }, { projection: { provider: 1 } })
    .toArray();
  return [...new Set<SignInMethod>([...localProviders(user), ...rows.map((r) => r.provider)])].sort();
}

/** The one shape the app ever sees an account in. */
export async function accountView(user: UserDoc): Promise<PublicUser> {
  // Non-null: `publicUser` only returns null for a null document, and this
  // signature does not admit one.
  return publicUser(user, { providers: await providersFor(user) }) as PublicUser;
}

/** [accountView] for a list, in two queries rather than 2N. */
export async function accountViews(users: UserDoc[]): Promise<PublicUser[]> {
  if (users.length === 0) return [];
  const identities = await collections.identities();
  const rows = await identities
    .find({ uid: { $in: users.map((u) => u.uid) } }, { projection: { uid: 1, provider: 1 } })
    .toArray();

  const byUid = new Map<string, SignInMethod[]>();
  for (const row of rows) {
    const list = byUid.get(row.uid) ?? [];
    list.push(row.provider);
    byUid.set(row.uid, list);
  }

  return users.map(
    (user) =>
      publicUser(user, {
        providers: [
          ...new Set<SignInMethod>([...localProviders(user), ...(byUid.get(user.uid) ?? [])]),
        ].sort(),
      }) as PublicUser,
  );
}

/** Case-insensitive: the address is lowercased on write and on lookup alike. */
export async function userByEmail(email: string | undefined): Promise<UserDoc | null> {
  const normalised = String(email ?? '').trim().toLowerCase();
  // Guarded, because the email index is sparse: `findOne({ email: '' })` would
  // match nothing, but `findOne({ email: null })` matches every phone-only
  // account — every document where the field is absent. An unguarded lookup
  // with an empty address would hand back a stranger.
  if (normalised.length === 0) return null;
  const users = await collections.users();
  return users.findOne({ email: normalised });
}

/** [phone] must already be E.164 — see `normalisePhone` in `services/phone`. */
export async function userByPhone(phone: string | undefined): Promise<UserDoc | null> {
  const normalised = String(phone ?? '').trim();
  if (normalised.length === 0) return null;
  const users = await collections.users();
  return users.findOne({ phone: normalised });
}

export async function userByUid(uid: string): Promise<UserDoc | null> {
  const users = await collections.users();
  return users.findOne({ uid });
}

export async function requireUser(uid: string): Promise<UserDoc> {
  const user = await userByUid(uid);
  if (!user) throw notFound('That account no longer exists.');
  return user;
}

export interface CreateUserInput {
  email?: string;
  password?: string;
  name?: string;
  phone?: string;
  emailVerified?: boolean;
  phoneVerified?: boolean;
  emailIsPrivateRelay?: boolean;
}

/**
 * Creates an account.
 *
 * The duplicate check is a unique index, not a read-then-write: two devices
 * registering the same address at the same moment both pass a prior read and
 * only one can pass the index. Catching 11000 here is what turns that race into
 * the right error instead of a 500.
 */
export async function createUser({
  email,
  password,
  name,
  phone,
  emailVerified = false,
  phoneVerified = false,
  emailIsPrivateRelay = false,
}: CreateUserInput = {}): Promise<UserDoc> {
  const now = new Date();
  const normalisedEmail = email ? String(email).trim().toLowerCase() : '';

  const doc: UserDoc = {
    uid: newUid(),
    name: (name ?? '').trim(),
    avatarId: 'avatar_01',
    emailVerified: normalisedEmail.length > 0 && emailVerified === true,
    phoneVerified: Boolean(phone) && phoneVerified === true,
    // The first administrator. A deployment names one address in
    // BOOTSTRAP_ADMIN_EMAIL; every admin after that is promoted through the API
    // by an existing one.
    //
    // Reachable through "Continue with Google" as well as through the
    // registration form, which is correct: the check is on the address, and a
    // social sign-in that arrives with the bootstrap address has had that
    // address *verified by the provider* — a stronger claim than the one the
    // password path makes.
    isAdmin: env.bootstrapAdminEmail.length > 0 && normalisedEmail === env.bootstrapAdminEmail,
    createdAt: now,
    updatedAt: now,
  };

  // Absent rather than empty, and this is load-bearing. `email` and `phone` are
  // *sparse* unique indexes: a document that omits the field is skipped by the
  // index, while a document storing `''` or `null` is indexed like any other
  // value — so writing an empty string would let exactly one phone-only account
  // exist and refuse the second with a duplicate key.
  if (normalisedEmail.length > 0) doc.email = normalisedEmail;
  if (phone) doc.phone = phone;
  if (emailIsPrivateRelay) doc.emailIsPrivateRelay = true;

  // Optional. An account created by "Continue with Google" or by a phone code
  // has no password and must not get a placeholder one — `verifyPassword`
  // already answers false for a missing hash, which is exactly the behaviour
  // wanted: there is no password, so no password is correct.
  if (password) doc.passwordHash = await hashPassword(password);

  try {
    const users = await collections.users();
    await users.insertOne(doc);
  } catch (error) {
    if ((error as { code?: number })?.code === 11000) {
      throw duplicateField(error) === 'phone' ? phoneInUse() : emailInUse();
    }
    throw error;
  }

  return doc;
}

/** Which unique index a duplicate-key error came from. */
function duplicateField(error: unknown): string {
  const pattern = (error as { keyPattern?: Record<string, unknown> })?.keyPattern;
  if (pattern && typeof pattern === 'object') return Object.keys(pattern)[0] ?? '';
  // Older drivers report only a message; the index name is in it.
  return /phone/.test((error as { message?: string })?.message ?? '') ? 'phone' : 'email';
}

/**
 * Sets or replaces the password, with no current-password check.
 *
 * The caller is responsible for having established that the request is
 * legitimate — a verified current password, or a consumed reset token, or (for
 * an account that has never had one) a live session. Kept here so bcrypt and
 * the round count stay in one module.
 */
export async function setPassword(uid: string, password: string): Promise<UserDoc> {
  return updateUser(uid, { passwordHash: await hashPassword(password) });
}

export async function updateUser(uid: string, patch: Partial<UserDoc>): Promise<UserDoc> {
  const users = await collections.users();
  const updated = await users.findOneAndUpdate(
    { uid },
    { $set: { ...patch, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
  if (!updated) throw notFound('That account no longer exists.');
  return updated;
}
