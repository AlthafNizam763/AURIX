import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { namedFields, playlistOut } from '@/server/services/playlists';
import { requirePlaylist, scopeOf } from '@/server/services/user-playlists';
import { notFound } from '@/server/utils/errors';

/** One playlist: read it, rename it, delete it. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth<{ id: string }>(async (_request, { auth, params }) => {
  const { id } = await params;
  return ok({ playlist: playlistOut(await requirePlaylist(auth.uid, id)) });
});

const patchSchema = z.object({
  name: z.string().trim().min(1).max(200),
  description: z.string().trim().max(1000).optional(),
});

export const PATCH = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const input = await body(request, patchSchema);

  const playlists = await collections.userPlaylists();
  const result = await playlists.updateOne(
    { uid: auth.uid, playlistId: id },
    {
      $set: {
        // The search index travels with the name, always.
        ...namedFields(input.name),
        ...(input.description !== undefined ? { description: input.description } : {}),
        updatedAt: new Date(),
      },
    },
  );

  if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
  return noContent();
});

export const DELETE = withAuth<{ id: string }>(async (_request, { auth, params }) => {
  const { id } = await params;

  const tracks = await collections.userPlaylistTracks();
  const playlists = await collections.userPlaylists();

  // Rows first: a playlist deleted before its tracks leaves orphans that no
  // query will ever reach again.
  await tracks.deleteMany(scopeOf(auth.uid, id));
  const result = await playlists.deleteOne({ uid: auth.uid, playlistId: id });

  if (result.deletedCount === 0) throw notFound('That playlist no longer exists.');
  return noContent();
});
