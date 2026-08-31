import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';

/**
 * Which of these tracks are liked.
 *
 * One request for a screenful, rather than one per row. The cap matters: an
 * unbounded `$in` is a way to make the server do arbitrary work on request.
 *
 * A static segment, so it takes precedence over the sibling `[trackId]` route —
 * `POST /library/liked/among` lands here rather than being read as a track id.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ trackIds: z.array(S.docId).max(1000) });

export const POST = withAuth(async (request, { auth }) => {
  const { trackIds } = await body(request, schema);
  if (trackIds.length === 0) return ok({ likedIds: [] });

  const likedTracks = await collections.likedTracks();
  const rows = await likedTracks
    .find({ uid: auth.uid, trackId: { $in: trackIds } }, { projection: { trackId: 1 } })
    .toArray();

  return ok({ likedIds: rows.map((row) => row.trackId) });
});
