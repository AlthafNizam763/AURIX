import { collections } from '@/server/db/mongo';
import { created, handler, ok } from '@/server/http/respond';
import { body, deviceField, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { OTP_PURPOSE, verifyOtp } from '@/server/services/otp';
import { normalisePhone } from '@/server/services/phone';
import { buildSession } from '@/server/services/session';
import { createUser, requireUser, userByPhone } from '@/server/services/users';
import { log } from '@/server/utils/logger';

/**
 * Redeems a phone code for a session, creating the account if it is new.
 *
 * Sign-in and registration are the same request here, deliberately: a phone
 * number that receives a code is proof of control either way, and asking someone
 * whether they already have an account is a question they should not have to
 * answer.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  phone: z.string().trim().min(3).max(32),
  code: z.string().trim().min(4).max(12),
  name: z.string().trim().max(80).optional(),
  device: deviceField,
});

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.otpVerify, request);
  const input = await body(request, schema);

  const phone = normalisePhone(input.phone);
  await verifyOtp({ destination: phone, purpose: OTP_PURPOSE.signIn, code: input.code });

  const existing = await userByPhone(phone);
  if (existing) {
    if (existing.phoneVerified !== true) {
      const users = await collections.users();
      await users.updateOne(
        { uid: existing.uid },
        { $set: { phoneVerified: true, updatedAt: new Date() } },
      );
    }
    return ok(
      await buildSession(await requireUser(existing.uid), { device: input.device }),
      200,
      headers,
    );
  }

  const user = await createUser({
    phone,
    phoneVerified: true,
    name: input.name ?? '',
  });

  log.info(`Registered ${user.uid} by phone`, 'auth');
  return created(await buildSession(user, { device: input.device, created: true }), headers);
});
