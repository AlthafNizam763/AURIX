import { handler, ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { ACTION, consumeActionToken, revokeAllRefreshTokens } from '@/server/services/tokens';
import { setPassword } from '@/server/services/users';

/**
 * Completes a password reset.
 *
 * The token is the whole authorisation — it was delivered to an address the
 * account owns — so it is consumed atomically and every existing session is
 * revoked. Someone resetting a password may be doing so because another party
 * has access.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ token: z.string().min(1), password: S.password });

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.reset, request);
  const { token, password } = await body(request, schema);

  const uid = await consumeActionToken(token, ACTION.resetPassword);
  await setPassword(uid, password);
  await revokeAllRefreshTokens(uid);

  return ok({ ok: true }, 200, headers);
});
