import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { buildSession } from '@/server/services/session';
import { revokeAllRefreshTokens } from '@/server/services/tokens';
import { requireUser, setPassword, verifyPassword } from '@/server/services/users';
import { unauthorized } from '@/server/utils/errors';

/** Changes the password, or sets a first one. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  /**
   * Optional since social and phone sign-in arrived. An account created by
   * "Continue with Google" has no password, and there is nothing for its owner
   * to type here — so this route doubles as "set a password", which is how such
   * an account gains one. It is safe because the caller holds a live session for
   * the account, which is the same standard the reset link meets.
   *
   * It stays *required* wherever a password exists: this must never become a way
   * to replace a password without knowing it.
   */
  currentPassword: z.string().min(1).max(200).optional(),
  newPassword: S.password,
});

export const POST = withAuth(async (request, { auth }) => {
  const headers = await enforce(LIMITS.credentials, request);
  const input = await body(request, schema);

  const user = await requireUser(auth.uid);
  const hasPassword =
    typeof user.passwordHash === 'string' && user.passwordHash.length > 0;

  if (hasPassword) {
    if (!input.currentPassword) {
      throw unauthorized('Enter your current password to change it.');
    }
    if (!(await verifyPassword(input.currentPassword, user.passwordHash))) {
      throw unauthorized('That current password is not correct.');
    }
  }

  await setPassword(user.uid, input.newPassword);

  // Every other session ends. A password change is what a user does after
  // suspecting someone else has their account, and leaving that someone signed
  // in on another device would defeat the point. The caller keeps working
  // because the response carries a fresh pair.
  await revokeAllRefreshTokens(user.uid);

  return ok(await buildSession(await requireUser(user.uid)), 200, headers);
});
