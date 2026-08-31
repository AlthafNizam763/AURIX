import { env } from '../config/env';
import { log } from '../utils/logger';

/**
 * Delivering a sign-in code to a handset.
 *
 * ## The one rule this module exists to enforce
 *
 * **A one-time code is a credential, and it leaves this process by exactly one
 * route: an SMS to the number that asked for it.** Not in a response body, not
 * in an error, not in a log line, not in a health check. Everything else here
 * is arrangements for making that true.
 *
 * This is stricter than the rule `mailer.ts` follows for password-reset links,
 * and the asymmetry is deliberate. A reset link is delivered to an address the
 * account already owns and is useless without the mailbox; a phone code is a
 * *complete* sign-in credential for whichever number was typed into an
 * unauthenticated endpoint. Printing one to a console makes anybody who can
 * read that console — a shared terminal, a log aggregator, a CI transcript —
 * able to sign in as anyone whose number they can spell.
 *
 * ## No transport means no phone sign-in
 *
 * There is no console fallback and no "returned in development" escape hatch.
 * When SMS is not configured, `env.phoneSignInEnabled` is false, the method is
 * not advertised by `GET /auth/methods`, and `POST /auth/phone/start` refuses
 * before a code is generated at all. Failing closed is the only honest answer:
 * a code the server cannot deliver is not a degraded sign-in.
 *
 * ## What the port removed, and why
 *
 * The Express version supported `OTP_DEV_DELIVERY=file`, which appended codes
 * to a git-ignored file on the machine running the server so the flow could be
 * exercised without an SMS account. It is **gone**, for two reasons that point
 * the same way: serverless has no durable filesystem to write to, and a
 * mechanism whose entire safety rests on "it is forced off in production" is
 * one fewer thing to be right about once it no longer has a home. Phone
 * sign-in now requires a real provider in every environment.
 *
 * ## Why there is no Twilio SDK
 *
 * Sending a message is one form-encoded POST with basic authentication. The SDK
 * is a dependency, a supply-chain surface and a version to keep current, in
 * exchange for wrapping `fetch`.
 */

const TWILIO_TIMEOUT_MS = 10_000;

/**
 * Sends an arbitrary message. Returns whether the provider accepted it.
 *
 * Never throws: a delivery failure must not fail the request in a way that
 * distinguishes one number from another. Callers decide what to tell the user.
 */
export async function sendSms(phone: string, text: string): Promise<boolean> {
  if (!env.smsEnabled) {
    // The message is deliberately *not* logged. It is the code.
    log.warn(`No SMS transport configured — nothing sent to ${phone}`, 'sms');
    return false;
  }

  const url = `https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(
    env.sms.accountSid,
  )}/Messages.json`;

  const body = new URLSearchParams({ To: phone, Body: text });
  // A messaging service is the better answer where one exists — it handles
  // sender selection and regional compliance — so it wins when both are set.
  if (env.sms.messagingServiceSid) {
    body.set('MessagingServiceSid', env.sms.messagingServiceSid);
  } else {
    body.set('From', env.sms.from);
  }

  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization:
          'Basic ' +
          Buffer.from(`${env.sms.accountSid}:${env.sms.authToken}`).toString('base64'),
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body,
      signal: AbortSignal.timeout(TWILIO_TIMEOUT_MS),
    });

    if (!response.ok) {
      // Twilio's own diagnosis — a malformed number, an unverified trial
      // recipient, a geographic permission switched off. Every one of those is
      // a configuration problem that otherwise presents as "the code never
      // arrives", and none of it echoes the message body.
      const detail = await response.text().catch(() => '');
      log.error(
        `Twilio refused the message to ${phone} (${response.status}): ${detail.slice(0, 400)}`,
        'sms',
      );
      return false;
    }

    log.info(`Delivered a sign-in code to ${phone}`, 'sms');
    return true;
  } catch (error) {
    log.error(`Could not reach the SMS provider for ${phone}`, 'sms', error);
    return false;
  }
}

/**
 * The sign-in code message. One place, so the wording cannot drift.
 *
 * Names the app and says what the code is for, because an unsolicited one is a
 * warning: somebody typed this number into AURIX's login screen.
 */
const signInMessage = (code: string): string =>
  `${code} is your AURIX sign-in code. It expires in ${env.otp.ttlMinutes} minutes. ` +
  'If you did not ask for it, ignore this message.';

/**
 * Puts [code] in front of the person holding [phone].
 *
 * The only function in the codebase that is given a plaintext one-time code,
 * and it returns a boolean rather than anything derived from it — so no caller
 * can accidentally propagate the value into a response.
 */
export async function deliverSignInCode(phone: string, code: string): Promise<boolean> {
  if (env.smsEnabled) return sendSms(phone, signInMessage(code));

  // Unreachable through the routes — `env.phoneSignInEnabled` is false here, so
  // `POST /auth/phone/start` has already refused and no code was generated.
  // Kept as a guard rather than an assertion because the cost of being wrong is
  // a credential going nowhere silently.
  log.error(
    'A sign-in code was generated with no way to deliver it. Configure Twilio.',
    'sms',
  );
  return false;
}
