import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { recount, scopeOf } from '@/server/services/user-playlists';

/** Removes many tracks in one request. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ trackIds: z.array(S.docId).max(5000) });

export const POST = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const { trackIds } = await body(request, schema);

  if (trackIds.length === 0) return ok({ removed: 0 });

  const tracks = await collections.userPlaylistTracks();
  const result = await tracks.deleteMany({
    ...scopeOf(auth.uid, id),
    trackId: { $in: trackIds },
  });

  await recount(auth.uid, id);
  return ok({ removed: result.deletedCount });
});
