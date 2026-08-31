import { env } from '@/server/config/env';
import { ok } from '@/server/http/respond';
import { withAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { sendEmailVerification } from '@/server/services/mailer';
import { ACTION, issueActionToken } from '@/server/services/tokens';
import { requireUser } from '@/server/services/users';

/** Sends, or resends, the address-confirmation email. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const POST = withAuth(async (request, { auth }) => {
  const headers = await enforce(LIMITS.reset, request);
  const user = await requireUser(auth.uid);

  if (user.emailVerified) return ok({ ok: true, alreadyVerified: true }, 200, headers);

  const { token } = await issueActionToken(user.uid, ACTION.verifyEmail);
  const sent = await sendEmailVerification(user.email!, token);

  const answer: { ok: true; devToken?: string } = { ok: true };
  // Development only, and only with no mail transport — the same gate the reset
  // route uses, for the same reason.
  if (!sent && !env.isProduction) answer.devToken = token;

  return ok(answer, 200, headers);
});
