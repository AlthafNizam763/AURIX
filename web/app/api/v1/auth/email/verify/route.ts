import { handler, ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { ACTION, consumeActionToken } from '@/server/services/tokens';
import { accountView, updateUser } from '@/server/services/users';

/** Confirms an email address from the token in the link. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ token: z.string().min(1) });

export const POST = handler(async (request) => {
  const { token } = await body(request, schema);
  const uid = await consumeActionToken(token, ACTION.verifyEmail);
  const user = await updateUser(uid, { emailVerified: true });
  return ok({ ok: true, user: await accountView(user) });
});
