import { handler, ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { buildSession } from '@/server/services/session';
import { rotateRefreshToken } from '@/server/services/tokens';
import { requireUser } from '@/server/services/users';

/**
 * Swaps a refresh token for a fresh pair.
 *
 * Rotation is what makes replay detectable: `rotateRefreshToken` deletes the
 * presented token in the same operation that authorises the new one, and refuses
 * if the delete matched nothing.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ refreshToken: z.string().min(1) });

export const POST = handler(async (request) => {
  const { refreshToken } = await body(request, schema);
  const uid = await rotateRefreshToken(refreshToken);
  return ok(await buildSession(await requireUser(uid)));
});
