import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, query, trackEntry, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { trackOut, writeTracksInOrder } from '@/server/services/playlists';
import { recount } from '@/server/services/shared-playlists';
import { limitOf } from '@/server/utils/json';

/**
 * The tracks of a shared playlist.
 *
 * Only `PUT` — write the whole list in the source's order. There is no append
 * here, unlike a user's own playlist: the shared catalogue mirrors an external
 * source rather than being curated by hand, so a re-sync replaces the order
 * wholesale.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const readSchema = z.object({ limit: z.string().optional() });

export const GET = withAuth<{ id: string }>(async (request, { params }) => {
  const id = S.docId.parse((await params).id);
  const { limit } = query(request, readSchema);

  const tracks = await collections.globalPlaylistTracks();
  const rows = await tracks
    .find({ playlistId: id })
    .sort({ position: 1 })
    .limit(limitOf(limit, { fallback: 2000, max: 5000 }))
    .toArray();

  return ok({ tracks: rows.map(trackOut) });
});

const writeSchema = z.object({ tracks: z.array(trackEntry).max(5000) });

export const PUT = withAuth<{ id: string }>(async (request, { params }) => {
  const id = S.docId.parse((await params).id);
  const input = await body(request, writeSchema);

  const tracks = await collections.globalPlaylistTracks();
  const written = await writeTracksInOrder(tracks, { playlistId: id }, input.tracks);
  await recount(id);

  return ok({ written });
});
