import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { accountView, requireUser, updateUser, verifyPassword } from '@/server/services/users';
import { badRequest, unauthorized } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/** The signed-in account: read it, rename it, delete it. */
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

// Optional for the same reason it is optional on `password/change`: an account
// created by a social sign-in or a phone code has no password, and requiring one
// here would leave its owner unable to delete their own account — with no way to
// acquire the thing being demanded.
const deleteSchema = z.object({ password: z.string().min(1).max(200).optional() });

export const DELETE = withAuth(async (request, { auth }) => {
  const input = await body(request, deleteSchema);
  const user = await requireUser(auth.uid);

  const hasPassword =
    typeof user.passwordHash === 'string' && user.passwordHash.length > 0;

  // Where a password exists it is still demanded, and still checked. A live
  // session is a weaker claim than a re-typed password — it is what a borrowed,
  // unlocked phone has — and deletion is irreversible.
  if (hasPassword && !(await verifyPassword(input.password ?? '', user.passwordHash))) {
    throw unauthorized('That password is not correct.');
  }

  const { uid } = user;

  const [
    likedTracks,
    recentlyPlayed,
    userPlaylists,
    userPlaylistTracks,
    refreshTokens,
    actionTokens,
    identities,
    users,
  ] = await Promise.all([
    collections.likedTracks(),
    collections.recentlyPlayed(),
    collections.userPlaylists(),
    collections.userPlaylistTracks(),
    collections.refreshTokens(),
    collections.actionTokens(),
    collections.identities(),
    collections.users(),
  ]);

  // Everything the account owns. The two shared collections are deliberately
  // untouched: a playlist someone imported into the shared catalogue is a
  // contribution other users are listening to, and deleting an account must not
  // delete their library. The provenance fields keep pointing at a uid that no
  // longer resolves, which is exactly what "imported by a former user" should
  // look like.
  await Promise.all([
    likedTracks.deleteMany({ uid }),
    recentlyPlayed.deleteMany({ uid }),
    userPlaylists.deleteMany({ uid }),
    userPlaylistTracks.deleteMany({ uid }),
    refreshTokens.deleteMany({ uid }),
    actionTokens.deleteMany({ uid }),
    // The linked provider accounts. Not deleting these would leave rows whose
    // unique `(provider, subject)` index blocks the same person from ever
    // signing up again with the Google account they used before.
    identities.deleteMany({ uid }),
  ]);
  await users.deleteOne({ uid });

  log.info(`Deleted account ${uid}`, 'auth');
  return noContent();
});
