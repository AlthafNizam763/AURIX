import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { OTP_PURPOSE, verifyOtp } from '@/server/services/otp';
import { normalisePhone } from '@/server/services/phone';
import { accountView, requireUser, userByPhone } from '@/server/services/users';
import { phoneInUse } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/** Attaches a phone number to the account that is already signed in. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  phone: z.string().trim().min(3).max(32),
  code: z.string().trim().min(4).max(12),
});

export const POST = withAuth(async (request, { auth }) => {
  const headers = await enforce(LIMITS.otpVerify, request);
  const input = await body(request, schema);

  const phone = normalisePhone(input.phone);

  const owner = await userByPhone(phone);
  if (owner && owner.uid !== auth.uid) throw phoneInUse();

  await verifyOtp({ destination: phone, purpose: OTP_PURPOSE.linkPhone, code: input.code });

  try {
    const users = await collections.users();
    await users.updateOne(
      { uid: auth.uid },
      { $set: { phone, phoneVerified: true, updatedAt: new Date() } },
    );
  } catch (error) {
    // The unique index is the real check — the read above cannot close the
    // window between two devices linking the same number at once.
    if ((error as { code?: number })?.code === 11000) throw phoneInUse();
    throw error;
  }

  log.info(`Linked a phone number to ${auth.uid}`, 'auth');
  return ok({ user: await accountView(await requireUser(auth.uid)) }, 200, headers);
});
