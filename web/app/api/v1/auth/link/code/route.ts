import { env } from '@/server/config/env';
import { handler, ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { sendAccountLinkCode } from '@/server/services/mailer';
import { peekGrant } from '@/server/services/oauth/flow';
import { providerLabel } from '@/server/services/oauth/providers';
import { OTP_PURPOSE, clearOtp, issueOtp } from '@/server/services/otp';
import { maskEmail, maskPhone } from '@/server/services/phone';
import { sendSms } from '@/server/services/sms';
import { requireUser } from '@/server/services/users';
import type { UserDoc } from '@/server/db/documents';
import { badRequest, unavailable } from '@/server/utils/errors';

/**
 * Sends a code proving ownership of the account a social sign-in just matched.
 *
 * The alternative proof is the account's password, which `/auth/link/confirm`
 * also accepts. This exists for accounts that have no password — created by a
 * phone code, or by a different provider — for which there would otherwise be no
 * way to complete a link at all.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ linkToken: z.string().trim().min(1).max(512) });

/** Where a code can be sent for this account, and how to describe it. */
function destinationFor(owner: UserDoc) {
  if (owner.email) {
    return { channel: 'email' as const, value: owner.email, masked: maskEmail(owner.email) };
  }
  if (owner.phone) {
    return { channel: 'sms' as const, value: owner.phone, masked: maskPhone(owner.phone) };
  }
  return null;
}

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.link, request);
  const { linkToken } = await body(request, schema);

  const record = await peekGrant(linkToken, 'link');
  const owner = await requireUser(String(record.uid));

  const target = destinationFor(owner);
  if (!target) {
    throw badRequest('That account has no address a code can be sent to. Use its password.');
  }

  const label = providerLabel(record.provider);
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

  return ok(
    {
      ok: true,
      message: 'OTP sent successfully',
      channel: target.channel,
      destination: target.masked,
      expiresInSeconds,
      resendInSeconds,
    },
    200,
    headers,
  );
});
