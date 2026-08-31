import type { UserDoc } from '@/server/db/documents';
import { handler, ok } from '@/server/http/respond';
import { body, deviceField, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { completeLink } from '@/server/services/identities';
import { countGrantAttempt, discardGrant, peekGrant } from '@/server/services/oauth/flow';
import { OTP_PURPOSE, verifyOtp } from '@/server/services/otp';
import { buildSession } from '@/server/services/session';
import { requireUser, verifyPassword } from '@/server/services/users';
import { badRequest, invalidAuthState, unauthorized } from '@/server/utils/errors';

/**
 * Completes an account link once ownership has been proved.
 *
 * Accepts *either* the account's password or the code sent by `/auth/link/code`.
 *
 * ## Why a wrong password burns the grant
 *
 * Without a counter this route would be an unmetered password oracle for the
 * account the grant names: an attacker who reached the link challenge could
 * guess indefinitely against a known address. `countGrantAttempt` destroys the
 * grant after five failures, at which point the whole browser flow has to be
 * started again.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  linkToken: z.string().trim().min(1).max(512),
  password: z.string().min(1).max(200).optional(),
  code: z.string().trim().min(4).max(12).optional(),
  device: deviceField,
});

function destinationFor(owner: UserDoc): string | null {
  return owner.email || owner.phone || null;
}

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.link, request);
  const input = await body(request, schema);

  const record = await peekGrant(input.linkToken, 'link');
  const owner = await requireUser(String(record.uid));

  const profile = record.payload?.profile;
  if (!profile?.subject) throw invalidAuthState();

  if (input.password) {
    if (!(await verifyPassword(input.password, owner.passwordHash))) {
      const alive = await countGrantAttempt(record);
      // Once the grant is gone the flow is over, and saying "wrong password"
      // would imply another attempt is possible.
      if (!alive) throw invalidAuthState();
      throw unauthorized('That password is not correct.');
    }
  } else if (input.code) {
    const destination = destinationFor(owner);
    if (!destination) throw invalidAuthState();
    await verifyOtp({
      destination,
      purpose: OTP_PURPOSE.linkAccount,
      code: input.code,
    });
  } else {
    throw badRequest('Confirm with the account password, or with the code we sent you.');
  }

  const user = await completeLink({ user: owner, provider: record.provider, profile });
  await discardGrant(input.linkToken);

  return ok(
    await buildSession(user, {
      device: input.device ?? record.payload?.device,
      provider: record.provider,
      linked: true,
    }),
    200,
    headers,
  );
});
