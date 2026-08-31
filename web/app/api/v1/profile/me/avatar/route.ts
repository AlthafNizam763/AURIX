import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { accountView, updateUser } from '@/server/services/users';

/**
 * Sets the avatar.
 *
 * An id naming one of the illustrations bundled with the app, not an upload —
 * which is why this is a small JSON write rather than anything touching GridFS.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ avatarId: z.string().trim().min(1).max(64) });

export const PUT = withAuth(async (request, { auth }) => {
  const { avatarId } = await body(request, schema);
  return ok({ user: await accountView(await updateUser(auth.uid, { avatarId })) });
});
