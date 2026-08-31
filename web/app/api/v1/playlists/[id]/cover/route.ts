import { collections } from '@/server/db/mongo';
import { noContent } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { notFound } from '@/server/utils/errors';

/**
 * Sets a playlist's cover.
 *
 * A URL, not an upload: covers come from the source the playlist was imported
 * from, or from artwork the app already has. Nothing is stored here but the
 * reference.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ coverUrl: S.url });

export const PUT = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const { coverUrl } = await body(request, schema);

  const playlists = await collections.userPlaylists();
  const result = await playlists.updateOne(
    { uid: auth.uid, playlistId: id },
    { $set: { coverUrl, updatedAt: new Date() } },
  );

  if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
  return noContent();
});
