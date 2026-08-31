import { env } from '@/server/config/env';
import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withOptionalAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { OTP_PURPOSE, clearOtp, issueOtp } from '@/server/services/otp';
import { maskPhone, normalisePhone } from '@/server/services/phone';
import { deliverSignInCode } from '@/server/services/sms';
import { userByPhone } from '@/server/services/users';
import { otpUnavailable, phoneInUse, unauthorized, unavailable } from '@/server/utils/errors';

/**
 * Sends a one-time code to a phone number.
 *
 * Refuses with `otp_unavailable` **before a code is generated** when no SMS
 * transport is configured. That ordering is the point: a code the server cannot
 * deliver is not a degraded sign-in, it is a credential generated and dropped.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  phone: z.string().trim().min(3).max(32),
  intent: z.enum(['signIn', 'link']).default('signIn'),
});

export const POST = withOptionalAuth(async (request, { auth }) => {
  const headers = await enforce(LIMITS.otpStart, request);
  const input = await body(request, schema);

  const phone = normalisePhone(input.phone);
  const linking = input.intent === 'link';

  if (linking && !auth?.uid) throw unauthorized();
  if (linking) {
    const owner = await userByPhone(phone);
    if (owner && owner.uid !== auth!.uid) throw phoneInUse();
  }

  if (!env.phoneSignInEnabled) throw otpUnavailable();

  const purpose = linking ? OTP_PURPOSE.linkPhone : OTP_PURPOSE.signIn;
  const { code, expiresInSeconds, resendInSeconds } = await issueOtp({
    destination: phone,
    purpose,
  });

  const delivered = await deliverSignInCode(phone, code);
  if (!delivered) {
    // Clear the code rather than leaving one live that nobody received — its
    // existence would only block the retry with a cooldown.
    await clearOtp({ destination: phone, purpose });
    throw unavailable('That code could not be sent. Try again in a moment.');
  }

  return ok(
    {
      ok: true,
      message: 'OTP sent successfully',
      phone: maskPhone(phone),
      expiresInSeconds,
      resendInSeconds,
    },
    200,
    headers,
  );
});
