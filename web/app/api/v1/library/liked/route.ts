import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { trackOut } from '@/server/services/playlists';
import { limitOf } from '@/server/utils/json';

/**
 * Liked songs.
 *
 * The uid is always the caller's, spliced in here and never taken from the
 * request — see `middleware/auth` for why that one rule is what replaced the
 * Firestore ownership rule.
 *
 * `trackOut` is shared with the playlist routes rather than redefined: the row
 * shape is the same, and the Express original had two copies that had already
 * begun to drift.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ limit: z.string().optional() });

export const GET = withAuth(async (request, { auth }) => {
  const { limit } = query(request, schema);
  const likedTracks = await collections.likedTracks();

  const rows = await likedTracks
    .find({ uid: auth.uid })
    // Newest first — the order Liked Songs has always shown, and the order the
    // `uid_createdAt` index is built to serve.
    .sort({ createdAt: -1 })
    .limit(limitOf(limit, { fallback: 500, max: 2000 }))
    .toArray();

  return ok({ tracks: rows.map(trackOut) });
});
