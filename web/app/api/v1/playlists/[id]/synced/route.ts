import { collections } from '@/server/db/mongo';
import { noContent } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { namedFields } from '@/server/services/playlists';
import { notFound } from '@/server/utils/errors';

/**
 * Records that a playlist has just been re-synced with its source.
 *
 * Name and cover are optional and only applied when non-empty: a source that
 * returns a blank title during a partial fetch must not wipe the one the user is
 * looking at.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  name: z.string().trim().max(200).optional(),
  coverUrl: S.url.optional(),
});

export const POST = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const input = await body(request, schema);

  const now = new Date();
  const $set: Record<string, unknown> = { syncedAt: now, updatedAt: now };
  if (input.name?.trim()) Object.assign($set, namedFields(input.name));
  if (input.coverUrl) $set.coverUrl = input.coverUrl;

  const playlists = await collections.userPlaylists();
  const result = await playlists.updateOne({ uid: auth.uid, playlistId: id }, { $set });

  if (result.matchedCount === 0) throw notFound('That playlist no longer exists.');
  return noContent();
});
