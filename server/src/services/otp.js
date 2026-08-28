import crypto from 'node:crypto';

import { env } from '../config/env.js';
import { collections } from '../db/mongo.js';
import { codeExpired, invalidCode, tooManyRequests } from '../utils/errors.js';

/**
 * One-time codes, for phone sign-in and for proving ownership during an
 * account link.
 *
 * ## What makes a six-digit code safe
 *
 * Not the six digits. One in a million is a *weak* secret on its own — a
 * script can try a million things in an afternoon — and every property that
 * makes this acceptable is a limit imposed here rather than entropy in the
 * code itself:
 *
 *  * **It expires.** Five minutes by default. The guessing window is not "until
 *    someone notices", it is `OTP_TTL_MINUTES`.
 *  * **It is burned after a handful of wrong guesses.** `OTP_MAX_ATTEMPTS`
 *    attempts against one code, counted on the code and not on the connection,
 *    so rotating IPs buys an attacker nothing.
 *  * **A new one cannot be summoned at will.** `OTP_SENDS_PER_HOUR` per
 *    destination. Without it, an attacker simply asks for a fresh code every
 *    time the old one burns and the attempt cap means nothing. This is also
 *    what stops the endpoint being used to bill a deployment for SMS.
 *  * **Requesting one invalidates the last.** A unique index on
 *    `(destination, purpose)` — so a code glimpsed on a lock screen an hour ago
 *    is not still live.
 *
 * ## Only the hash is stored
 *
 * The same discipline as passwords and refresh tokens: a leaked backup of
 * `otpCodes` must not contain a live credential. The comparison is
 * constant-time, which matters more here than it does for a password, because
 * the search space is small enough that a timing oracle would genuinely help.
 *
 * ## Destinations, not phone numbers
 *
 * Keyed on an opaque `destination` string so the same machinery serves the
 * emailed code that confirms an account link. The purpose is part of the key,
 * so a code issued to sign in cannot be replayed to authorise a link.
 */

export const OTP_PURPOSE = {
  /** Sign in, or create an account, with a phone number. */
  signIn: 'sign_in',
  /** Attach a phone number to the account that is already signed in. */
  linkPhone: 'link_phone',
  /** Prove ownership of an existing account during a social account link. */
  linkAccount: 'link_account',
};

const sha256 = (value) => crypto.createHash('sha256').update(value).digest();

/** Decimal digits, from the platform CSPRNG. `Math.random` here is a bug. */
function generateCode(length) {
  const max = 10 ** length;
  return String(crypto.randomInt(0, max)).padStart(length, '0');
}

/**
 * Issues a code, enforcing both send limits.
 *
 * Returns the plaintext code so the caller can deliver it. That is the only
 * moment it exists outside the caller's stack — nothing logs it, and nothing
 * puts it in a response outside the no-transport development path.
 */
export async function issueOtp({ destination, purpose }) {
  const now = Date.now();

  // 1. The cooldown, which is what makes the app's "Resend in 30s" honest
  //    rather than decorative.
  const live = await collections.otpCodes().findOne({ destination, purpose });
  if (live?.createdAt instanceof Date) {
    const waited = (now - live.createdAt.getTime()) / 1000;
    if (waited < env.otp.resendSeconds) {
      throw tooManyRequests(
        `Wait ${Math.ceil(env.otp.resendSeconds - waited)} seconds before asking for another code.`,
      );
    }
  }

  // 2. The hourly cap. Counted from a ledger rather than from a counter on the
  //    code document, because the code document is deleted on every successful
  //    verification — a counter there would reset itself for free.
  const windowStart = new Date(now - 60 * 60 * 1000);
  const sent = await collections
    .otpSends()
    .countDocuments({ destination, createdAt: { $gte: windowStart } });
  if (sent >= env.otp.sendsPerHour) {
    throw tooManyRequests('Too many codes requested for that number. Try again later.');
  }

  const code = generateCode(env.otp.length);
  const expiresAt = new Date(now + env.otp.ttlMinutes * 60 * 1000);

  await collections.otpCodes().replaceOne(
    { destination, purpose },
    {
      destination,
      purpose,
      codeHash: sha256(code),
      attempts: 0,
      createdAt: new Date(now),
      expiresAt,
    },
    { upsert: true },
  );

  await collections.otpSends().insertOne({
    destination,
    createdAt: new Date(now),
    // The ledger only has to outlive the window it is counted over.
    expiresAt: new Date(now + 60 * 60 * 1000),
  });

  return {
    code,
    expiresAt,
    expiresInSeconds: env.otp.ttlMinutes * 60,
    resendInSeconds: env.otp.resendSeconds,
  };
}

/**
 * Checks a code and consumes it. Throws rather than returning false, so no
 * call site can forget to branch.
 */
export async function verifyOtp({ destination, purpose, code }) {
  const record = await collections.otpCodes().findOne({ destination, purpose });

  // No live code is reported as a wrong code, not as "nothing was sent".
  // Distinguishing the two tells an attacker which numbers have a sign-in in
  // progress, which is the same enumeration leak the login route avoids.
  if (!record) throw invalidCode();

  if (record.expiresAt instanceof Date && record.expiresAt.getTime() < Date.now()) {
    await collections.otpCodes().deleteOne({ _id: record._id });
    throw codeExpired();
  }

  // Incremented *before* the comparison, so a client that hangs up on a wrong
  // answer has still spent an attempt.
  const attempts = (record.attempts ?? 0) + 1;
  if (attempts > env.otp.maxAttempts) {
    await collections.otpCodes().deleteOne({ _id: record._id });
    throw tooManyRequests('Too many incorrect codes. Ask for a new one.');
  }
  await collections
    .otpCodes()
    .updateOne({ _id: record._id }, { $set: { attempts } });

  const supplied = sha256(String(code ?? ''));
  const stored = record.codeHash?.buffer ? Buffer.from(record.codeHash.buffer) : record.codeHash;
  if (!Buffer.isBuffer(stored) || !crypto.timingSafeEqual(supplied, stored)) {
    throw invalidCode();
  }

  await collections.otpCodes().deleteOne({ _id: record._id });
  return true;
}

/** Drops any live code for a destination — used when a flow is abandoned. */
export async function clearOtp({ destination, purpose }) {
  await collections.otpCodes().deleteOne({ destination, purpose });
}
