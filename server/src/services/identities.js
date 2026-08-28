import { collections } from '../db/mongo.js';
import { isApplePrivateRelay, providerLabel } from './oauth/providers.js';
import {
  createUser,
  localProviders,
  providersFor,
  requireUser,
  updateUser,
  userByEmail,
  userByUid,
} from './users.js';
import { identityInUse, lastSignInMethod, notFound } from '../utils/errors.js';
import { log } from '../utils/logger.js';

/**
 * One person, many ways in — the rule that keeps them one account.
 *
 * ## The problem this module exists to solve
 *
 * Somebody registers with alex@example.com and a password. Six months later
 * they tap "Continue with Google" on a new phone. Naively, that is a second
 * AURIX account: an empty library, none of their playlists, and no way to
 * discover why. Naively the other way — signing them straight in because the
 * addresses match — is worse: it means anybody who can get a provider to
 * assert an address can walk into the account that owns it.
 *
 * So there are exactly three outcomes here, and every social sign-in produces
 * one of them:
 *
 *  1. **Known identity.** The `(provider, subject)` pair is already in the
 *     table. Sign in. This is the overwhelmingly common case and it costs one
 *     indexed lookup.
 *  2. **New identity, unknown person.** No matching account. Create one, and
 *     attach the identity to it.
 *  3. **New identity, known address.** A verified email that already belongs to
 *     an AURIX account. *Do not sign in and do not create a second account* —
 *     return a link challenge and make the caller prove they own the existing
 *     account first.
 *
 * ## Why case 3 is a challenge rather than an automatic link
 *
 * There is a respectable argument for linking automatically when both sides
 * assert a verified address: Google confirmed the mailbox, AURIX confirmed the
 * same mailbox, so both parties independently proved control of it. Several
 * large identity providers do exactly that.
 *
 * It is not what happens here, for one reason: AURIX accounts can exist with
 * `emailVerified: false` — registration does not block on the confirmation
 * email — so "the account claims this address" is not the same statement as
 * "somebody proved they read mail at this address". Auto-linking would let a
 * person who registered with *your* address, and never confirmed it, receive
 * your Google identity and everything attached to it.
 *
 * Challenging always is one extra step in a flow people run once per device,
 * and it removes the whole class of problem rather than the easy half of it.
 *
 * ## `subject`, not email, is the identity
 *
 * The key is `(provider, subject)`: the provider's own immutable id for the
 * account. Email addresses change, get reassigned by corporate IT, and in
 * Apple's case may be a per-application relay. A user who changes their Gmail
 * address keeps the same `sub` and keeps their AURIX account; a user whose old
 * address is handed to a new employee does not hand over their library with it.
 */

/** Identity kinds that are not rows in this collection. */
export const LOCAL_PROVIDERS = ['password', 'phone'];

export async function identitiesFor(uid) {
  return collections
    .identities()
    .find({ uid }, { projection: { _id: 0, codeHash: 0 } })
    .sort({ createdAt: 1 })
    .toArray();
}

export function findIdentity(provider, subject) {
  return collections.identities().findOne({ provider, subject: String(subject) });
}

/**
 * Attaches a provider account to an AURIX user.
 *
 * The unique index on `(provider, subject)` is the actual guarantee, not the
 * read that precedes it: two devices completing the same link at the same
 * moment both pass any prior check and only one can pass the index. Catching
 * 11000 here is what turns that race into "already linked elsewhere" instead
 * of a 500.
 */
export async function attachIdentity({ uid, provider, profile }) {
  const now = new Date();
  const row = {
    uid,
    provider,
    subject: String(profile.subject),
    email: profile.email || undefined,
    emailVerified: profile.emailVerified === true,
    isPrivateRelay: profile.isPrivateRelay === true,
    displayName: profile.name || '',
    avatarUrl: profile.avatarUrl || '',
    updatedAt: now,
  };

  try {
    // The filter carries `uid`, and that is the whole safety of this call.
    //
    // Filtering on `(provider, subject)` alone would make this an *update* when
    // the identity already belongs to somebody else — silently moving their
    // Google account onto this one. With the uid in the filter, that case
    // matches nothing, the upsert becomes an insert, and the unique index on
    // `(provider, subject)` refuses it. The read in `resolveSocial` catches it
    // first in the ordinary case; this is what closes the window between that
    // read and this write.
    await collections.identities().updateOne(
      { provider, subject: row.subject, uid },
      { $set: row, $setOnInsert: { createdAt: now } },
      { upsert: true },
    );
  } catch (error) {
    if (error?.code === 11000) throw identityInUse(providerLabel(provider));
    throw error;
  }

  return row;
}

/**
 * Removes a way in, refusing to remove the last one.
 *
 * The check counts *everything* — password, phone and every linked provider —
 * because the failure mode is permanent. An account with no identity left has
 * no sign-in path and no recovery path either: a password reset needs an
 * address to send to, and there is nobody to send it to.
 */
export async function detachIdentity({ uid, provider }) {
  const user = await requireUser(uid);
  const all = await providersFor(user);
  if (!all.includes(provider)) throw notFound('That sign-in method is not linked.');
  if (all.length <= 1) throw lastSignInMethod();

  if (provider === 'phone') {
    // `$unset`, not `phone: null`. The index is sparse, and a null would be
    // indexed like any other value — so the second account to "remove" its
    // phone this way would collide with the first.
    await collections
      .users()
      .updateOne({ uid }, { $unset: { phone: '', phoneVerified: '' }, $set: { updatedAt: new Date() } });
    return;
  }

  if (provider === 'password') {
    await collections
      .users()
      .updateOne({ uid }, { $unset: { passwordHash: '' }, $set: { updatedAt: new Date() } });
    return;
  }

  await collections.identities().deleteOne({ uid, provider });
}

/**
 * The address a provider profile may be *matched* on.
 *
 * Narrower than "the email the provider gave us", and each exclusion is load
 * bearing:
 *
 *  * **Unverified** addresses are excluded because anyone can type anyone's
 *    address into a GitHub or Google profile. Matching on one would let an
 *    attacker claim the AURIX account belonging to any address they can spell.
 *  * **Apple's private relay** is excluded because it is minted per
 *    application: it will never equal another account's address, and treating
 *    it as a person's email address means storing something they would not
 *    recognise as theirs.
 *
 * An empty result is not a failure — it means this sign-in creates its own
 * account, which is the correct outcome when there is nothing trustworthy to
 * match against.
 */
export function matchableEmail(profile) {
  const email = String(profile?.email ?? '').trim().toLowerCase();
  if (email.length === 0) return '';
  if (profile.emailVerified !== true) return '';
  if (profile.isPrivateRelay === true || isApplePrivateRelay(email)) return '';
  return email;
}

/** Fills in what an account is missing, and never overwrites what it has. */
async function backfill(user, profile) {
  const patch = {};

  // A name only ever fills a gap. Signing in with Google must not rename an
  // account whose owner deliberately set something else.
  if (!user.name && profile.name) patch.name = profile.name.trim();

  // The provider just proved control of the address this account claims. That
  // is a stronger proof than the confirmation email AURIX would have sent, so
  // it settles the question.
  if (
    !user.emailVerified &&
    user.email &&
    profile.emailVerified === true &&
    String(profile.email ?? '').toLowerCase() === user.email
  ) {
    patch.emailVerified = true;
  }

  if (Object.keys(patch).length === 0) return user;
  return updateUser(user.uid, patch);
}

/**
 * Turns a provider profile into one of the three outcomes described above.
 *
 * ```
 * { kind: 'session', user, created }  — sign this person in
 * { kind: 'link',    user }           — prove you own this account first
 * ```
 *
 * [intent] is `'link'` when the caller is already signed in and is adding a
 * method from Settings; the account is then known up front and there is
 * nothing to challenge, because holding a valid session *is* the proof.
 */
export async function resolveSocial({ provider, profile, intent = 'signIn', actorUid }) {
  const subject = String(profile?.subject ?? '');
  if (subject.length === 0) {
    throw notFound('That provider did not identify an account.');
  }

  const existing = await findIdentity(provider, subject);

  // ---- Adding a method to the account that is already signed in ----------
  if (intent === 'link') {
    const actor = await requireUser(actorUid);
    if (existing && existing.uid !== actor.uid) throw identityInUse(providerLabel(provider));
    await attachIdentity({ uid: actor.uid, provider, profile });
    const updated = await backfill(await requireUser(actor.uid), profile);
    return { kind: 'session', user: updated, created: false, linked: true };
  }

  // ---- 1. A provider account we have seen before -------------------------
  if (existing) {
    const user = await userByUid(existing.uid);
    if (user) {
      // Refreshed on every sign-in so a changed address or display name on the
      // provider side does not go stale in our copy of it.
      await attachIdentity({ uid: user.uid, provider, profile });
      return { kind: 'session', user: await backfill(user, profile), created: false };
    }
    // The account was deleted and the row outlived it. Clear it and carry on
    // as though this identity were new — the alternative is a sign-in that
    // fails forever with no way for the user to fix it.
    log.warn(`Identity ${provider}:${subject} pointed at a deleted account`, 'auth');
    await collections.identities().deleteOne({ provider, subject });
  }

  // ---- 3. A verified address that already belongs to somebody ------------
  const email = matchableEmail(profile);
  if (email) {
    const owner = await userByEmail(email);
    if (owner) return { kind: 'link', user: owner };
  }

  // ---- 2. Nobody we know. A new account ----------------------------------
  //
  // The address is stored even when it cannot be *matched* on — an Apple relay
  // address is a real, deliverable mailbox and is the only way to reach this
  // account — but it is flagged, so nothing downstream mistakes it for an
  // address the user would recognise as their own.
  const storedEmail =
    profile.emailVerified === true ? String(profile.email ?? '').trim().toLowerCase() : '';
  const privateRelay = storedEmail.length > 0 && (profile.isPrivateRelay === true || isApplePrivateRelay(storedEmail));

  let user;
  try {
    user = await createUser({
      email: storedEmail,
      name: profile.name,
      emailVerified: storedEmail.length > 0,
      emailIsPrivateRelay: privateRelay,
    });
  } catch (error) {
    // Two sign-ins for the same new address at the same instant. One of them
    // created the account a moment ago; this one should link to it, not fail.
    if (error?.code === 'email_in_use' || error?.status === 409) {
      const owner = await userByEmail(storedEmail);
      if (owner) return { kind: 'link', user: owner };
    }
    throw error;
  }

  await attachIdentity({ uid: user.uid, provider, profile });
  log.info(`Created ${user.uid} from ${provider}`, 'auth');
  return { kind: 'session', user, created: true };
}

/**
 * Completes a link once ownership of the existing account has been proved.
 *
 * The proof itself — a password, or a code mailed to the account's address —
 * is checked by the route. This is what happens after it succeeds.
 */
export async function completeLink({ user, provider, profile }) {
  await attachIdentity({ uid: user.uid, provider, profile });
  const updated = await backfill(await requireUser(user.uid), profile);
  log.info(`Linked ${provider} to ${user.uid}`, 'auth');
  return updated;
}

/** The methods an account has, for the "you usually sign in with…" copy. */
export async function signInMethodsFor(user) {
  const rows = await collections
    .identities()
    .find({ uid: user.uid }, { projection: { provider: 1 } })
    .toArray();
  return [...new Set([...localProviders(user), ...rows.map((r) => r.provider)])].sort();
}
