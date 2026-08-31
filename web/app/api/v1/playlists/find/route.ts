import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { playlistOut } from '@/server/services/playlists';

/**
 * Finds one of the caller's playlists by where it was imported from.
 *
 * The duplicate-import check: before pulling a Spotify playlist in again, the
 * app asks whether this account already has it. Answers `{playlist: null}`
 * rather than a 404, because "you have not imported this" is an answer and not
 * a failure.
 *
 * A static segment, so it wins over the sibling `[id]` route.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  source: z.string().trim().min(1).max(32),
  sourceId: z.string().trim().min(1).max(220),
});

export const GET = withAuth(async (request, { auth }) => {
  const { source, sourceId } = query(request, schema);

  const playlists = await collections.userPlaylists();
  const doc = await playlists.findOne({ uid: auth.uid, source, sourceId });

  return ok({ playlist: playlistOut(doc) });
});
