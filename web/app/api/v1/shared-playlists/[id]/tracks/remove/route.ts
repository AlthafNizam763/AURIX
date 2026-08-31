import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { recount } from '@/server/services/shared-playlists';

/** Removes tracks from a shared playlist — used when a re-sync finds them gone. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ trackIds: z.array(S.docId).max(5000) });

export const POST = withAuth<{ id: string }>(async (request, { params }) => {
  const id = S.docId.parse((await params).id);
  const { trackIds } = await body(request, schema);

  if (trackIds.length === 0) return ok({ removed: 0 });

  const tracks = await collections.globalPlaylistTracks();
  const result = await tracks.deleteMany({ playlistId: id, trackId: { $in: trackIds } });

  await recount(id);
  return ok({ removed: result.deletedCount });
});
