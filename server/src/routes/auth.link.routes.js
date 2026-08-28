import express from 'express';
import rateLimit from 'express-rate-limit';

import { env } from '../config/env.js';
import { validate, z } from '../middleware/validate.js';
import { completeLink } from '../services/identities.js';
import { sendAccountLinkCode } from '../services/mailer.js';
import {
  countGrantAttempt,
  discardGrant,
  peekGrant,
} from '../services/oauth/flow.js';
import { providerLabel } from '../services/oauth/providers.js';
import { OTP_PURPOSE, clearOtp, issueOtp, verifyOtp } from '../services/otp.js';
import { maskEmail, maskPhone } from '../services/phone.js';
import { buildSession } from '../services/session.js';
import { sendSms } from '../services/sms.js';
import { requireUser, verifyPassword } from '../services/users.js';
import { route } from '../utils/async.js';
import { badRequest, invalidAuthState, unauthorized, unavailable } from '../utils/errors.js';

/**
 * Joining a social identity to an AURIX account that already exists.
 *
 * Mounted at `/api/v1/auth/link`. Reached only when
 * `POST /auth/oauth/exchange` answered `linkRequired` — that is, when a
 * provider asserted a verified address that already belongs to somebody here.
 *
 * ## What is being proved, and to whom
 *
 * At this point two facts are established and one is missing. Established: the
 * provider vouches for the address, and an AURIX account claims the same
 * address. Missing: that these are the same person. Anyone can register an
 * AURIX account with an address they do not own — nothing blocks on the
 * confirmation email — so "both sides say alex@example.com" is not yet an
 * argument for handing over the account.
 *
 * So the caller proves control of the *existing* account, by one of two means:
 *
 *  * **Its password**, if it has one. Instant, and the common case for an
 *    account that started life on the registration form.
 *  * **A code sent to its address**, otherwise. This is the path for an
 *    account that was itself created by a social sign-in and has no password —
 *    and it is a real proof, because delivery is what the address means.
 *
 * ## Why the grant counts attempts
 *
 * A `link` grant names an account and accepts a password. Without a counter
 * that is an unmetered password oracle for whichever account the attacker can
 * get a provider to match. Five wrong answers destroy the grant and the whole
 * flow restarts from the consent screen.
 */
const router = express.Router();

const linkLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 20 : 200,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many attempts. Try again in a few minutes.' } },
});

const tokenField = z.string().trim().min(1).max(512);

/** Where a confirmation code for [owner] can actually be delivered. */
function destinationFor(owner) {
  if (owner.email) return { channel: 'email', value: owner.email, masked: maskEmail(owner.email) };
  if (owner.phone) return { channel: 'sms', value: owner.phone, masked: maskPhone(owner.phone) };
  return null;
}

/**
 * Sends a confirmation code to the account being linked to.
 *
 * Note where it goes: to the *existing account's* address, not to the address
 * the provider supplied — even though the two are equal, which is what caused
 * the challenge. Reading the value off the account document rather than off
 * the incoming profile means a provider that lies about an address still only
 * ever causes mail to be sent to the account's own owner.
 *
 * For that owner, an unexpected one of these is the notification that somebody
 * else is trying to get into their account. The mail says as much.
 */
router.post(
  '/code',
  linkLimiter,
  validate({ body: z.object({ linkToken: tokenField }) }),
  route(async (req, res) => {
    const record = await peekGrant(req.body.linkToken, 'link');
    const owner = await requireUser(record.uid);
    const target = destinationFor(owner);

    if (!target) {
      throw badRequest('That account has no address a code can be sent to. Use its password.');
    }

    const label = providerLabel(record.provider);

    // Checked before a code is minted, so a deployment that cannot deliver
    // never burns the destination's hourly allowance or invalidates a code the
    // user may still be holding.
    const deliverable = target.channel === 'email' ? env.mailEnabled : env.phoneSignInEnabled;
    if (!deliverable) {
      throw unavailable(
        owner.passwordHash
          ? 'A code cannot be sent right now. Use the account password instead.'
          : 'A code cannot be sent right now. Try again later.',
      );
    }

    const { code, expiresInSeconds, resendInSeconds } = await issueOtp({
      destination: target.value,
      purpose: OTP_PURPOSE.linkAccount,
    });

    const sent =
      target.channel === 'email'
        ? await sendAccountLinkCode(target.value, code, label)
        : await sendSms(
            target.value,
            `${code} is your AURIX code for linking ${label} to your account.`,
          );

    if (!sent) {
      await clearOtp({ destination: target.value, purpose: OTP_PURPOSE.linkAccount });
      throw unavailable('That code could not be sent. Try again in a moment.');
    }

    // Timings and a masked destination. The code itself is never returned —
    // the same rule `auth.phone.routes.js` follows, and for the same reason:
    // it is a complete credential for the account it names.
    res.json({
      ok: true,
      message: 'OTP sent successfully',
      channel: target.channel,
      destination: target.masked,
      expiresInSeconds,
      resendInSeconds,
    });
  }),
);

/**
 * Proves ownership and joins the two.
 *
 * Returns a full session, so completing a link *is* signing in — which is what
 * the user was trying to do when they tapped "Continue with Google". Making
 * them sign in again afterwards would be asking for the proof twice.
 */
router.post(
  '/confirm',
  linkLimiter,
  validate({
    body: z.object({
      linkToken: tokenField,
      password: z.string().min(1).max(200).optional(),
      code: z.string().trim().min(4).max(12).optional(),
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const record = await peekGrant(req.body.linkToken, 'link');
    const owner = await requireUser(record.uid);
    const profile = record.payload?.profile;

    if (!profile?.subject) throw invalidAuthState();

    if (req.body.password) {
      const ok = await verifyPassword(req.body.password, owner.passwordHash ?? '');
      if (!ok) {
        // Counted on the grant, not on the connection. An attacker who rotates
        // addresses still gets five guesses at this account and then has to
        // walk back through a provider consent screen for another five.
        const alive = await countGrantAttempt(record);
        if (!alive) throw invalidAuthState();
        throw unauthorized('That password is not correct.');
      }
    } else if (req.body.code) {
      const target = destinationFor(owner);
      if (!target) throw invalidAuthState();
      // Throws on a wrong or expired code, and keeps its own attempt count —
      // see `services/otp.js`, which burns the code after five.
      await verifyOtp({
        destination: target.value,
        purpose: OTP_PURPOSE.linkAccount,
        code: req.body.code,
      });
    } else {
      throw badRequest('Confirm with the account password, or with the code we sent you.');
    }

    const user = await completeLink({ user: owner, provider: record.provider, profile });
    await discardGrant(req.body.linkToken);

    res.json(
      await buildSession(user, {
        device: req.body.device ?? record.payload?.device,
        provider: record.provider,
        linked: true,
      }),
    );
  }),
);

/**
 * Abandons a pending link.
 *
 * Worth an endpoint rather than leaving it to the ten-minute TTL: "no, that is
 * not my account" is a thing a user will say, and the honest response is to
 * destroy the grant then rather than to leave a live challenge naming a
 * stranger's account sitting in the database.
 */
router.post(
  '/cancel',
  validate({ body: z.object({ linkToken: tokenField }) }),
  route(async (req, res) => {
    await discardGrant(req.body.linkToken);
    res.status(204).end();
  }),
);

export default router;
