import crypto from 'node:crypto';
import bcrypt from 'bcryptjs';

import { env } from '../config/env.js';
import { collections } from '../db/mongo.js';
import { emailInUse, notFound, phoneInUse } from '../utils/errors.js';
import { iso } from '../utils/async.js';

/**
 * The user record — AURIX's identity, now owned by MongoDB.
 *
 * ## `uid` is still the primary key
 *
 * Not `_id`. Every per-user collection keys on `uid`, and that indirection is
 * worth keeping rather than collapsing onto Mongo's `ObjectId`: the uid appears
 * in the app's own models (`AurixUser.uid`), in cached rows on the device, and
 * in `importedByUserId` on shared playlists. Making it an opaque string the
 * server allocates means none of those had to change shape when identity moved
 * off Firebase, and it leaves room for a future identity provider to supply one.
 *
 * ## Password storage
 *
 * bcrypt at cost 12. The hash never leaves this module — `publicUser` exists so
 * that no route can accidentally serialise a user document straight to a
 * response, which is exactly how password hashes get published.
 */

const BCRYPT_ROUNDS = 12;

/** A uid with the same shape and entropy budget Firebase Auth used. */
export function newUid() {
  return crypto.randomBytes(14).toString('base64url').slice(0, 28);
}

export const hashPassword = (password) => bcrypt.hash(password, BCRYPT_ROUNDS);
export const verifyPassword = (password, hash) =>
  typeof hash === 'string' && hash.length > 0 ? bcrypt.compare(password, hash) : Promise.resolve(false);

/**
 * The only shape a user is ever sent to a client in.
 *
 * Mirrors `AurixUser` on the Dart side field for field. Timestamps are ISO-8601
 * strings, which `Json.timestamp` already parses — that is why the model needed
 * no change when Firestore's `Timestamp` went away.
 */
export function publicUser(doc, { providers } = {}) {
  if (!doc) return null;
  return {
    uid: doc.uid,
    name: doc.name ?? '',
    email: doc.email ?? '',
    phone: doc.phone ?? '',
    avatarId: doc.avatarId ?? 'avatar_01',
    emailVerified: doc.emailVerified === true,
    phoneVerified: doc.phoneVerified === true,
    // Apple's private relay. A real, deliverable address, but one Apple
    // minted for this application alone — so it is not the user's email in
    // any sense they would recognise, and a profile screen that renders it
    // without saying so looks broken. See `handlePrivateRelay` in
    // `services/identities.js` for the rules that follow from this flag.
    emailIsPrivateRelay: doc.emailIsPrivateRelay === true,
    isAdmin: doc.isAdmin === true,
    // Which ways in this account has. Present so Settings can show what is
    // linked and refuse to unlink the last one, and so the sign-in screen can
    // say "you usually continue with Google" during an account link.
    //
    // Callers that have not loaded the identity rows get the two that live on
    // the user document itself. [accountView] is what fills in the rest, and
    // it is what every route the *app* calls uses.
    providers: providers ?? localProviders(doc),
    createdAt: iso(doc.createdAt),
    updatedAt: iso(doc.updatedAt),
  };
}

/** The sign-in methods recorded on the user document, with no second read. */
export function localProviders(doc) {
  const out = [];
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
export async function providersFor(user) {
  if (!user) return [];
  const rows = await collections
    .identities()
    .find({ uid: user.uid }, { projection: { provider: 1 } })
    .toArray();
  return [...new Set([...localProviders(user), ...rows.map((r) => r.provider)])].sort();
}

/** The one shape the app ever sees an account in. */
export async function accountView(user) {
  return publicUser(user, { providers: await providersFor(user) });
}

/** [accountView] for a list, in two queries rather than 2N. */
export async function accountViews(users) {
  if (users.length === 0) return [];
  const rows = await collections
    .identities()
    .find({ uid: { $in: users.map((u) => u.uid) } }, { projection: { uid: 1, provider: 1 } })
    .toArray();

  const byUid = new Map();
  for (const row of rows) {
    if (!byUid.has(row.uid)) byUid.set(row.uid, []);
    byUid.get(row.uid).push(row.provider);
  }

  return users.map((user) =>
    publicUser(user, {
      providers: [
        ...new Set([...localProviders(user), ...(byUid.get(user.uid) ?? [])]),
      ].sort(),
    }),
  );
}

/** Case-insensitive: the address is lowercased on write and on lookup alike. */
export async function userByEmail(email) {
  const normalised = String(email ?? '').trim().toLowerCase();
  // Guarded, because the email index is sparse now: `findOne({ email: '' })`
  // would match nothing, but `findOne({ email: null })` matches every
  // phone-only account — every document where the field is absent. An
  // unguarded lookup with an empty address would hand back a stranger.
  if (normalised.length === 0) return null;
  return collections.users().findOne({ email: normalised });
}

/** [phone] must already be E.164 — see `normalisePhone` in `services/phone.js`. */
export async function userByPhone(phone) {
  const normalised = String(phone ?? '').trim();
  if (normalised.length === 0) return null;
  return collections.users().findOne({ phone: normalised });
}

export async function userByUid(uid) {
  return collections.users().findOne({ uid });
}

export async function requireUser(uid) {
  const user = await userByUid(uid);
  if (!user) throw notFound('That account no longer exists.');
  return user;
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
} = {}) {
  const now = new Date();
  const normalisedEmail = email ? String(email).trim().toLowerCase() : '';

  const doc = {
    uid: newUid(),
    name: (name ?? '').trim(),
    avatarId: 'avatar_01',
    emailVerified: normalisedEmail.length > 0 && emailVerified === true,
    phoneVerified: Boolean(phone) && phoneVerified === true,
    // The first administrator. A deployment names one address in
    // BOOTSTRAP_ADMIN_EMAIL; every admin after that is promoted through the
    // API by an existing one.
    //
    // Reachable through "Continue with Google" as well as through the
    // registration form, which is correct: the check is on the address, and a
    // social sign-in that arrives with the bootstrap address has had that
    // address *verified by the provider* — a stronger claim than the one the
    // password path makes.
    isAdmin:
      env.bootstrapAdminEmail.length > 0 && normalisedEmail === env.bootstrapAdminEmail,
    createdAt: now,
    updatedAt: now,
  };

  // Absent rather than empty, and this is load-bearing. `email` and `phone`
  // are *sparse* unique indexes: a document that omits the field is skipped by
  // the index, while a document storing `''` or `null` is indexed like any
  // other value — so writing an empty string would let exactly one
  // phone-only account exist and refuse the second with a duplicate key.
  if (normalisedEmail.length > 0) doc.email = normalisedEmail;
  if (phone) doc.phone = phone;
  if (emailIsPrivateRelay) doc.emailIsPrivateRelay = true;

  // Optional. An account created by "Continue with Google" or by a phone code
  // has no password and must not get a placeholder one — `verifyPassword`
  // already answers false for a missing hash, which is exactly the behaviour
  // wanted: there is no password, so no password is correct.
  if (password) doc.passwordHash = await hashPassword(password);

  try {
    await collections.users().insertOne(doc);
  } catch (error) {
    if (error?.code === 11000) {
      throw duplicateField(error) === 'phone' ? phoneInUse() : emailInUse();
    }
    throw error;
  }

  return doc;
}

/** Which unique index a duplicate-key error came from. */
function duplicateField(error) {
  const pattern = error?.keyPattern;
  if (pattern && typeof pattern === 'object') return Object.keys(pattern)[0] ?? '';
  // Older drivers report only a message; the index name is in it.
  return /phone/.test(error?.message ?? '') ? 'phone' : 'email';
}

/**
 * Sets or replaces the password, with no current-password check.
 *
 * The caller is responsible for having established that the request is
 * legitimate — a verified current password, or a consumed reset token, or (for
 * an account that has never had one) a live session. Kept here so `bcrypt` and
 * the round count stay in one module.
 */
export async function setPassword(uid, password) {
  return updateUser(uid, { passwordHash: await hashPassword(password) });
}

export async function updateUser(uid, patch) {
  const $set = { ...patch, updatedAt: new Date() };
  const updated = await collections
    .users()
    .findOneAndUpdate({ uid }, { $set }, { returnDocument: 'after' });
  if (!updated) throw notFound('That account no longer exists.');
  return updated;
}
