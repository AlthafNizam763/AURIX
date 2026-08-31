import { handler, ok } from '@/server/http/respond';
import { S, body, deviceField, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { buildSession } from '@/server/services/session';
import { userByEmail, verifyPassword } from '@/server/services/users';
import { invalidCredentials } from '@/server/utils/errors';

/**
 * Sign in with an email address and a password.
 *
 * Rate limited per IP, and that limit is load-bearing rather than hygienic:
 * without it this endpoint is an offline password cracker with a network hop.
 * bcrypt at cost 12 makes each guess expensive for the server too, so the
 * limiter also protects our own CPU.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  email: S.email,
  // Not `S.password`: an existing account may predate any policy change, and
  // rejecting a short password at *sign-in* would lock its owner out while
  // telling an attacker the length rule.
  password: z.string().min(1).max(200),
  device: deviceField,
});

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.credentials, request);
  const { email, password, device } = await body(request, schema);

  const user = await userByEmail(email);

  // One error for "no such account" and for "wrong password", and the hash
  // comparison runs either way. **Both halves matter**: distinct messages leak
  // which addresses are registered, and skipping bcrypt on a missing account
  // leaks the same thing through response timing. `verifyPassword` answers false
  // for an empty hash rather than throwing, which is what makes the second half
  // expressible.
  const okPassword = await verifyPassword(password, user?.passwordHash ?? '');
  if (!user || !okPassword) throw invalidCredentials();

  return ok(await buildSession(user, { device }), 200, headers);
});
