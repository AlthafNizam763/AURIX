import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { accountView, requireUser, updateUser } from '@/server/services/users';

/**
 * Fills in anything a freshly created account is missing.
 *
 * Called by the app after a sign-in. Only ever *adds* — a name is written when
 * there is none, never over one the user chose — because a social sign-in
 * arriving with a provider display name must not rename an account whose owner
 * deliberately set something else.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  name: S.displayName.optional(),
  email: S.email.optional(),
});

export const POST = withAuth(async (request, { auth }) => {
  const input = await body(request, schema);
  const user = await requireUser(auth.uid);

  const patch: Record<string, unknown> = {};
  if (!user.name && input.name) patch.name = input.name;
  if (!user.avatarId) patch.avatarId = 'avatar_01';

  const result =
    Object.keys(patch).length > 0 ? await updateUser(user.uid, patch) : user;

  return ok({ user: await accountView(result) });
});
