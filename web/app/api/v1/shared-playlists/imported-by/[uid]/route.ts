import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { playlistOut } from '@/server/services/playlists';

/**
 * The shared playlists a given account imported.
 *
 * ## Why this takes a uid and is not `withSelf`
 *
 * It looks like the profile route, which is guarded, and it is deliberately not.
 * `importedByUserId` on a shared playlist is **provenance, not ownership**: the
 * catalogue is readable by every signed-in user, and "what did this person
 * contribute" is a question the catalogue is meant to answer. Nothing private is
 * reachable through it — every document it returns is already readable by id.
 *
 * The distinction is the one drawn in `db/collections`: recorded, not enforcing.
 * Only `DELETE` consults the same field to enforce anything.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth<{ uid: string }>(async (_request, { params }) => {
  const uid = S.uid.parse((await params).uid);

  const playlists = await collections.globalPlaylists();
  const rows = await playlists
    .find({ importedByUserId: uid })
    .sort({ importedAt: -1 })
    .limit(500)
    .toArray();

  return ok({ playlists: rows.map(playlistOut) });
});
