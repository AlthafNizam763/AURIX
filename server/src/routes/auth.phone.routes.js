import express from 'express';
import rateLimit from 'express-rate-limit';

import { env } from '../config/env.js';
import { collections } from '../db/mongo.js';
import { optionalAuth, requireAuth } from '../middleware/auth.js';
import { validate, z } from '../middleware/validate.js';
import { OTP_PURPOSE, clearOtp, issueOtp, verifyOtp } from '../services/otp.js';
import { maskPhone, normalisePhone } from '../services/phone.js';
import { buildSession } from '../services/session.js';
import { deliverSignInCode } from '../services/sms.js';
import { accountView, createUser, requireUser, userByPhone } from '../services/users.js';
import { route } from '../utils/async.js';
import { otpUnavailable, phoneInUse, unauthorized, unavailable } from '../utils/errors.js';
import { log } from '../utils/logger.js';

/**
 * Sign in with a phone number.
 *
 * Mounted at `/api/v1/auth/phone`.
 *
 * ## One flow, two endings
 *
 * `POST /start` sends a code. `POST /verify` redeems it and returns **the same
 * session payload every other sign-in method returns** — see
 * `services/session.js`, which is the point of that module existing. Whether
 * the number was already known decides only whether an account is created;
 * the client sees no difference and needs no branch.
 *
 * `POST /link` is the same code, redeemed against a session that already
 * exists, which attaches the number to that account instead. It is what stops
 * a user who registered by email and later "signs in with their phone" from
 * ending up with two accounts.
 *
 * ## The code goes to the handset and nowhere else
 *
 * `/start` returns timings and a masked number. It does **not** return the
 * code, in any environment, under any configuration — and neither does any log
 * line, error message or health check. The plaintext exists inside
 * [issueAndDeliver] and inside the SMS request body, and nowhere else in the
 * process.
 *
 * There is consequently no console fallback: a deployment with no SMS
 * transport does not offer phone sign-in at all. `GET /auth/methods` leaves it
 * out, so the button never appears, and `/start` refuses with `otp_unavailable`
 * before a code is generated. See `services/sms.js` for why this is stricter
 * than the rule password-reset links follow, and for the git-ignored file sink
 * that makes the flow developable without an SMS account.
 *
 * ## What is deliberately not distinguished
 *
 * `/start` answers identically for a number that has an AURIX account and one
 * that does not. There is no branch to leak, because phone sign-in *is* phone
 * registration — but the endpoint would still be a subscriber-enumeration
 * oracle if it said so, and it costs nothing not to.
 *
 * ## Three independent limits
 *
 * The per-IP limiter below and the two per-destination limits inside
 * `issueOtp` defend against different attacks and none substitutes for
 * another:
 *
 *  * **Per IP**, here — stops one host working through many numbers.
 *  * **Per number, per hour** — stops many hosts working through one number,
 *    and stops this endpoint being used to bill a deployment for SMS.
 *  * **Per code** — five wrong guesses burn it, counted on the code rather
 *    than the connection, so rotating addresses buys an attacker nothing.
 */
const router = express.Router();

const startLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 15 : 200,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many requests. Try again in a few minutes.' } },
});

const verifyLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: env.isProduction ? 30 : 300,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: { code: 'rate_limited', message: 'Too many attempts. Try again in a few minutes.' } },
});

const phoneField = z.string().trim().min(3).max(32);
const codeField = z.string().trim().min(4).max(12);

/**
 * Generates a code and hands it to the SMS layer.
 *
 * **The plaintext code never leaves this function.** It is created here, passed
 * to [deliverSignInCode], and goes out of scope — the caller gets timings and a
 * masked number, and there is no branch, development or otherwise, that puts it
 * in a response. See `services/sms.js` for why this is stricter than the rule
 * password-reset links follow.
 *
 * The availability check happens *before* [issueOtp], so a server with no
 * transport never mints a credential it cannot deliver, never burns the
 * caller's hourly send allowance, and never invalidates a code they might
 * still be holding from an earlier working attempt.
 */
async function issueAndDeliver({ phone, purpose }) {
  if (!env.phoneSignInEnabled) throw otpUnavailable();

  const { code, expiresInSeconds, resendInSeconds } = await issueOtp({
    destination: phone,
    purpose,
  });

  const delivered = await deliverSignInCode(phone, code);
  if (!delivered) {
    // The provider refused or was unreachable. Drop the code rather than
    // leaving a live credential nobody received — otherwise the next request
    // is refused by the one-live-code rule and the resend cooldown, for a
    // message that never arrived.
    await clearOtp({ destination: phone, purpose });
    throw unavailable('That code could not be sent. Try again in a moment.');
  }

  return { expiresInSeconds, resendInSeconds };
}

router.post(
  '/start',
  startLimiter,
  optionalAuth,
  validate({
    body: z.object({
      phone: phoneField,
      /** `link` attaches the number to the session that is already open. */
      intent: z.enum(['signIn', 'link']).default('signIn'),
    }),
  }),
  route(async (req, res) => {
    const phone = normalisePhone(req.body.phone);
    const linking = req.body.intent === 'link';

    if (linking && !req.user?.uid) throw unauthorized();

    if (linking) {
      // Checked before a code is sent, not after it is entered. Sending a
      // code that cannot possibly be redeemed wastes an SMS and, worse, tells
      // the recipient that somebody is trying to attach their number to an
      // account — for a request that was always going to fail.
      const owner = await userByPhone(phone);
      if (owner && owner.uid !== req.user.uid) throw phoneInUse();
    }

    const { expiresInSeconds, resendInSeconds } = await issueAndDeliver({
      phone,
      purpose: linking ? OTP_PURPOSE.linkPhone : OTP_PURPOSE.signIn,
    });

    // Timings and a masked number. Nothing here identifies the code, and
    // nothing here differs between a number that has an AURIX account and one
    // that does not.
    res.json({
      ok: true,
      message: 'OTP sent successfully',
      phone: maskPhone(phone),
      expiresInSeconds,
      resendInSeconds,
    });
  }),
);

router.post(
  '/verify',
  verifyLimiter,
  validate({
    body: z.object({
      phone: phoneField,
      code: codeField,
      /** Offered on first sign-in; ignored for a number already known. */
      name: z.string().trim().max(80).optional(),
      device: z.string().max(120).optional(),
    }),
  }),
  route(async (req, res) => {
    const phone = normalisePhone(req.body.phone);
    await verifyOtp({ destination: phone, purpose: OTP_PURPOSE.signIn, code: req.body.code });

    const existing = await userByPhone(phone);
    if (existing) {
      // A number that reaches a handset the holder controls is the strongest
      // claim available on this path, so a successful code settles it even for
      // an account that predates the flag.
      if (existing.phoneVerified !== true) {
        await collections
          .users()
          .updateOne({ uid: existing.uid }, { $set: { phoneVerified: true, updatedAt: new Date() } });
      }
      return res.json(await buildSession(await requireUser(existing.uid), { device: req.body.device }));
    }

    // No account. Phone sign-in *is* phone registration — there is no second
    // screen to send someone to, and an error here would be a dead end for a
    // person who has just proved they hold the number.
    //
    // No email address is stored, and none is invented. `createUser` omits the
    // field entirely rather than writing '' — which is what makes the sparse
    // unique index on `users.email` hold for more than one such account.
    const user = await createUser({
      phone,
      phoneVerified: true,
      name: req.body.name ?? '',
    });

    log.info(`Registered ${user.uid} by phone`, 'auth');
    res.status(201).json(await buildSession(user, { device: req.body.device, created: true }));
  }),
);

/**
 * Attaches a number to the account that is already signed in.
 *
 * Returns the account rather than a session: the caller is already
 * authenticated and rotating their tokens here would be churn for nothing. The
 * refreshed `providers` list is the part that matters — it is what makes the
 * new method appear in Settings without a reload.
 */
router.post(
  '/link',
  requireAuth,
  verifyLimiter,
  validate({ body: z.object({ phone: phoneField, code: codeField }) }),
  route(async (req, res) => {
    const phone = normalisePhone(req.body.phone);

    // Re-checked after the code is verified as well as before it was sent.
    // The window between the two is small and somebody else can register the
    // number inside it; the unique index would refuse the write anyway, and
    // this turns that into the right error rather than a 500.
    const owner = await userByPhone(phone);
    if (owner && owner.uid !== req.user.uid) throw phoneInUse();

    await verifyOtp({ destination: phone, purpose: OTP_PURPOSE.linkPhone, code: req.body.code });

    try {
      await collections
        .users()
        .updateOne(
          { uid: req.user.uid },
          { $set: { phone, phoneVerified: true, updatedAt: new Date() } },
        );
    } catch (error) {
      if (error?.code === 11000) throw phoneInUse();
      throw error;
    }

    log.info(`Linked a phone number to ${req.user.uid}`, 'auth');
    res.json({ user: await accountView(await requireUser(req.user.uid)) });
  }),
);

export default router;
