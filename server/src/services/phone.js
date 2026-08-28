import { env } from '../config/env.js';
import { invalidPhone } from '../utils/errors.js';

/**
 * Phone numbers, in exactly one spelling.
 *
 * ## Why normalisation is a correctness problem and not a tidiness one
 *
 * `users.phone` carries a **unique** index and `otpCodes.destination` keys the
 * live one-time code. Both of those are string comparisons, so every spelling
 * of a number that reaches them has to already be the same string — otherwise
 * "+44 7700 900123" registers an account, "+447700900123" registers a second
 * one, and a code sent to one of them cannot be redeemed against the other.
 *
 * ## Why there is no phone-number library here
 *
 * `libphonenumber` is 500KB of national numbering plans, and the only thing it
 * would buy is validating that a number is *plausible* for its country. AURIX
 * does not need that: the code either arrives at a real handset or it does not,
 * and a number that fails to receive an SMS is rejected by reality a few
 * seconds later. What is needed is a canonical form, which is E.164 and is
 * mechanical.
 *
 * The one judgement call is a number typed without a country code. There is no
 * way to resolve `07700 900123` without knowing the region, so this refuses it
 * unless the deployment has named a default — guessing would mean sending
 * somebody else's phone a sign-in code.
 */

/** Separators a person might type. Dashes include the en and em variants. */
const SEPARATORS = /[\s()\-.\u2013\u2014]/g;

/** Returns [raw] in E.164 (`+` then 7–15 digits), or throws [invalidPhone]. */
export function normalisePhone(raw) {
  let value = String(raw ?? '').trim();
  if (value.length === 0) throw invalidPhone();

  value = value.replace(SEPARATORS, '');

  // `00` is the international access prefix in most of the world, and people
  // who dial abroad type it far more often than they type `+`.
  if (value.startsWith('00')) value = `+${value.slice(2)}`;

  if (!value.startsWith('+')) {
    const country = env.defaultPhoneCountryCode;
    if (!country.startsWith('+')) throw invalidPhone();
    // A national number is conventionally written with a trunk prefix — the
    // leading 0 in `07700 900123` — which is *not* part of the E.164 form.
    value = `${country}${value.replace(/^0+/, '')}`;
  }

  const digits = value.slice(1);
  // E.164: at most 15 digits, and a country code never begins with 0.
  if (!/^[1-9]\d{6,14}$/.test(digits)) throw invalidPhone();

  return `+${digits}`;
}

/** True when [raw] is already a well-formed E.164 number. */
export function isE164(raw) {
  return typeof raw === 'string' && /^\+[1-9]\d{6,14}$/.test(raw);
}

/**
 * `+447700900123` → `+44•••••123`.
 *
 * Shown when telling someone which number a code went to, or which account an
 * identity is about to be linked to. Enough to recognise your own number and
 * not enough to learn a stranger's.
 */
export function maskPhone(phone) {
  if (typeof phone !== 'string' || phone.length < 5) return '';
  const head = phone.slice(0, 3);
  const tail = phone.slice(-3);
  return `${head}${'•'.repeat(Math.max(3, phone.length - 6))}${tail}`;
}

/** `alex@example.com` → `al•••@example.com`. Same job as [maskPhone]. */
export function maskEmail(email) {
  if (typeof email !== 'string') return '';
  const at = email.indexOf('@');
  if (at <= 0) return '';
  const local = email.slice(0, at);
  const visible = local.slice(0, Math.min(2, local.length));
  return `${visible}${'•'.repeat(Math.max(3, local.length - visible.length))}${email.slice(at)}`;
}
