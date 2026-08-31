import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { body, trackEntry, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { appendTracks } from '@/server/services/playlists';
import { recount, requirePlaylist, scopeOf } from '@/server/services/user-playlists';

/**
 * Appends many tracks in one request.
 *
 * The append semantics of `POST /tracks`, batched: positions continue after the
 * current last, and a track already present keeps where the user put it.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ tracks: z.array(trackEntry).max(5000) });

export const POST = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const input = await body(request, schema);

  await requirePlaylist(auth.uid, id);
  const tracks = await collections.userPlaylistTracks();
  const added = await appendTracks(tracks, scopeOf(auth.uid, id), input.tracks);
  await recount(auth.uid, id);

  return ok({ added });
});
