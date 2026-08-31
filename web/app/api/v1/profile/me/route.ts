import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { accountView, requireUser, updateUser } from '@/server/services/users';
import { badRequest } from '@/server/utils/errors';

/**
 * The signed-in account's profile.
 *
 * Overlaps `/auth/me` on purpose: the app's profile screen and its auth layer
 * are separate concerns that happen to read the same document, and collapsing
 * them would make a change to one a change to the other.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth(async (_request, { auth }) =>
  ok({ user: await accountView(await requireUser(auth.uid)) }),
);

const patchSchema = z.object({
  name: S.displayName.optional(),
  avatarId: z.string().trim().max(64).optional(),
});

export const PATCH = withAuth(async (request, { auth }) => {
  const input = await body(request, patchSchema);

  const patch: Record<string, unknown> = {};
  if (input.name !== undefined) patch.name = input.name;
  if (input.avatarId !== undefined) patch.avatarId = input.avatarId;
  if (Object.keys(patch).length === 0) throw badRequest('Nothing to update.');

  return ok({ user: await accountView(await updateUser(auth.uid, patch)) });
});
