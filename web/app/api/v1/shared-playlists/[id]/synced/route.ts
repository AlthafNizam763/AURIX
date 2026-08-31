import { collections } from '@/server/db/mongo';
import { noContent } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { namedFields } from '@/server/services/playlists';
import { notFound } from '@/server/utils/errors';

/** Records that a shared playlist has been re-synced with its source. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  name: z.string().trim().max(200).optional(),
  coverUrl: S.url.optional(),
});

export const POST = withAuth<{ id: string }>(async (request, { params }) => {
  const id = S.docId.parse((await params).id);
  const input = await body(request, schema);

  const now = new Date();
  const $set: Record<string, unknown> = { syncedAt: now, updatedAt: now };
  if (input.name?.trim()) Object.assign($set, namedFields(input.name));
  if (input.coverUrl) $set.coverUrl = input.coverUrl;

  const playlists = await collections.globalPlaylists();
  const result = await playlists.updateOne({ _id: id }, { $set });

  if (result.matchedCount === 0) {
    throw notFound('That playlist is no longer in the catalogue.');
  }
  return noContent();
});
