import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { body, query, trackEntry, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { appendTracks, trackOut, writeTracksInOrder } from '@/server/services/playlists';
import { recount, requirePlaylist, scopeOf } from '@/server/services/user-playlists';
import { limitOf } from '@/server/utils/json';

/**
 * The tracks in one playlist.
 *
 * Three verbs with three different orderings, and the difference matters:
 *
 *  * `POST` **appends** — position assigned after the current last, and set only
 *    on insert, so re-adding a track already present does not move it.
 *  * `PUT` **replaces the order** — positions assigned from the list index, so
 *    the playlist ends up in the source's order. What a re-sync wants.
 *  * `GET` reads by `position`, which the compound index serves directly.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const readSchema = z.object({ limit: z.string().optional() });

export const GET = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const { limit } = query(request, readSchema);

  const tracks = await collections.userPlaylistTracks();
  const rows = await tracks
    .find(scopeOf(auth.uid, id))
    .sort({ position: 1 })
    .limit(limitOf(limit, { fallback: 2000, max: 5000 }))
    .toArray();

  return ok({ tracks: rows.map(trackOut) });
});

export const POST = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const entry = await body(request, trackEntry);

  await requirePlaylist(auth.uid, id);
  const tracks = await collections.userPlaylistTracks();
  await appendTracks(tracks, scopeOf(auth.uid, id), [entry]);
  await recount(auth.uid, id);

  return noContent();
});

const bulkSchema = z.object({ tracks: z.array(trackEntry).max(5000) });

export const PUT = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const input = await body(request, bulkSchema);

  await requirePlaylist(auth.uid, id);
  const tracks = await collections.userPlaylistTracks();
  const written = await writeTracksInOrder(tracks, scopeOf(auth.uid, id), input.tracks);
  await recount(auth.uid, id);

  return ok({ written });
});
