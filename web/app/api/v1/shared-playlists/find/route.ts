import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { playlistOut } from '@/server/services/playlists';

/**
 * Finds a shared playlist by where it came from.
 *
 * Tried by `(source, sourceId)` first and by `sourceUrl` second, because a
 * pasted link is sometimes all the app has before it has resolved the id.
 * Answers `{playlist: null}` rather than 404 — "nobody has imported this yet" is
 * an answer, and it is the one that starts an import.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  source: z.string().trim().max(32).optional(),
  sourceId: z.string().trim().max(220).optional(),
  sourceUrl: z.string().trim().max(2048).optional(),
});

export const GET = withAuth(async (request) => {
  const { source, sourceId, sourceUrl } = query(request, schema);
  const playlists = await collections.globalPlaylists();

  let doc = null;
  if (source && sourceId) doc = await playlists.findOne({ source, sourceId });
  if (!doc && sourceUrl) doc = await playlists.findOne({ sourceUrl });

  return ok({ playlist: playlistOut(doc) });
});
