import { collections } from '@/server/db/mongo';
import { noContent } from '@/server/http/respond';
import { S } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { recount, scopeOf } from '@/server/services/user-playlists';

/** Removes one track from a playlist. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const DELETE = withAuth<{ id: string; trackId: string }>(
  async (_request, { auth, params }) => {
    const { id, trackId } = await params;
    const validated = S.docId.parse(trackId);

    const tracks = await collections.userPlaylistTracks();
    await tracks.deleteOne({ ...scopeOf(auth.uid, id), trackId: validated });

    await recount(auth.uid, id);
    return noContent();
  },
);
