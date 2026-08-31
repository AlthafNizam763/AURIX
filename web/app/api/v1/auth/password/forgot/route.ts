import { env } from '@/server/config/env';
import { handler, ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { sendPasswordReset } from '@/server/services/mailer';
import { ACTION, issueActionToken } from '@/server/services/tokens';
import { userByEmail } from '@/server/services/users';

/** Starts a password reset. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ email: S.email });

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.reset, request);
  const { email } = await body(request, schema);

  const user = await userByEmail(email);

  // Always the same response. Reporting "no such account" here turns this
  // endpoint into an address-enumeration oracle, which is the one thing a
  // password-reset form must not be.
  const answer: { ok: true; message: string; devToken?: string } = {
    ok: true,
    message: 'If that address has an AURIX account, a reset link is on its way.',
  };

  if (!user) return ok(answer, 200, headers);

  const { token } = await issueActionToken(user.uid, ACTION.resetPassword);
  const sent = await sendPasswordReset(user.email!, token);

  // Outside production only, and only when there is no mail transport: the flow
  // has to be testable on a machine with no SMTP. `env.isProduction` is the gate
  // that keeps this from being an account-takeover endpoint — returning a reset
  // token to whoever asks is a full takeover for any address an attacker can
  // name.
  if (!sent && !env.isProduction) answer.devToken = token;

  return ok(answer, 200, headers);
});
