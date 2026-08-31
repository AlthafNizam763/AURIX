import nodemailer, { type Transporter } from 'nodemailer';

import { env } from '../config/env';
import { log } from '../utils/logger';

/**
 * Outbound mail for password resets, email verification and account linking.
 *
 * ## No SMTP is a supported configuration
 *
 * Firebase Auth sent these emails for free, and a migration that made "forgot
 * password" depend on a mail provider being configured would break the flow for
 * every deployment that has not set one up yet. So when SMTP is absent the
 * token is logged instead, and — outside production only — returned in the
 * response so the flow can be exercised end to end.
 *
 * That `devToken` is gated on `NODE_ENV !== 'production'` in the route rather
 * than here, and it is worth being explicit about why the gate matters: a
 * production deployment with no SMTP configured must fail closed. Returning a
 * password-reset token in an HTTP response to whoever asks is a full account
 * takeover for any email address an attacker can name.
 *
 * ## The transport is cached on `globalThis`
 *
 * For the same reason the Mongo client is: Next re-evaluates modules on every
 * edit in development, and a module-local `let` would build a fresh SMTP
 * connection pool on each one.
 */

interface MailerCache {
  transport: Transporter | null;
}

const globalForMail = globalThis as typeof globalThis & { __aurixMail?: MailerCache };
const cache: MailerCache = (globalForMail.__aurixMail ??= { transport: null });

function getTransport(): Transporter | null {
  if (!env.mailEnabled) return null;
  cache.transport ??= nodemailer.createTransport({
    host: env.smtp.host,
    port: env.smtp.port,
    secure: env.smtp.secure,
    auth: { user: env.smtp.user, pass: env.smtp.pass },
  });
  return cache.transport;
}

async function send({
  to,
  subject,
  text,
  sensitive = false,
}: {
  to: string;
  subject: string;
  text: string;
  sensitive?: boolean;
}): Promise<boolean> {
  const mailer = getTransport();

  if (!mailer) {
    // `sensitive` suppresses the body. A password-reset link is delivered to an
    // address the account already owns and is useless without the mailbox, so
    // logging it in development is a reasonable convenience. A one-time *code*
    // is not: it is a complete credential, and anyone who can read the console
    // can use it. See the note at the top of `services/sms.ts`.
    log.warn(
      `No SMTP configured — "${subject}" for ${to} was not sent` +
        (sensitive ? '.' : `:\n${text}`),
      'mail',
    );
    return false;
  }

  try {
    await mailer.sendMail({ from: env.smtp.from, to, subject, text });
    log.info(`Sent "${subject}" to ${to}`, 'mail');
    return true;
  } catch (error) {
    // A mail failure must not fail the request. "If that address is registered,
    // a link is on its way" is the correct response either way, and telling the
    // caller that delivery failed would confirm the address exists.
    log.error(`Could not send "${subject}" to ${to}`, 'mail', error);
    return false;
  }
}

function link(path: string, token: string): string | null {
  if (!env.publicAppUrl) return null;
  const base = env.publicAppUrl.replace(/\/+$/, '');
  return `${base}${path}?token=${encodeURIComponent(token)}`;
}

export async function sendPasswordReset(to: string, token: string): Promise<boolean> {
  const url = link('/reset-password', token);
  const body = url
    ? `Open this link to choose a new AURIX password:\n\n${url}\n\nIt expires in ${env.actionTokenMinutes} minutes. If you did not ask for this, ignore this email — nothing has changed.`
    : `Your AURIX password reset code:\n\n${token}\n\nEnter it in the app. It expires in ${env.actionTokenMinutes} minutes. If you did not ask for this, ignore this email — nothing has changed.`;

  return send({ to, subject: 'Reset your AURIX password', text: body });
}

export async function sendEmailVerification(to: string, token: string): Promise<boolean> {
  const url = link('/verify-email', token);
  const body = url
    ? `Confirm your email address for AURIX:\n\n${url}\n\nThis link expires in ${env.actionTokenMinutes} minutes.`
    : `Your AURIX verification code:\n\n${token}\n\nEnter it in the app. It expires in ${env.actionTokenMinutes} minutes.`;

  return send({ to, subject: 'Confirm your AURIX email address', text: body });
}

/**
 * The code that proves you own the AURIX account a social sign-in just matched.
 *
 * Sent when someone continues with Google (or Apple, Facebook, GitHub) and the
 * verified address on that provider account already belongs to an AURIX user.
 * The mail names the provider deliberately: if the recipient did not just tap
 * "Continue with Google", this is the notification that somebody else did.
 */
export async function sendAccountLinkCode(
  to: string,
  code: string,
  provider: string,
): Promise<boolean> {
  const body =
    `Your AURIX account-linking code:\n\n${code}\n\n` +
    `Enter it in the app to add ${provider} as a way to sign in to this account. ` +
    `It expires in ${env.otp.ttlMinutes} minutes.\n\n` +
    `If you did not just try to sign in with ${provider}, ignore this email — ` +
    'nothing has been linked, and nobody can sign in to your account without this code.';

  return send({
    to,
    subject: `Link ${provider} to your AURIX account`,
    text: body,
    // Never logged, in any environment: this is a one-time code, not a link.
    sensitive: true,
  });
}
