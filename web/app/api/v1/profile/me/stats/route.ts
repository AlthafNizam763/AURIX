import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { withAuth } from '@/server/middleware/auth';

/** Counts for the profile screen. Three indexed counts, run together. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth(async (_request, { auth }) => {
  const { uid } = auth;

  const [likedTracks, userPlaylists, recentlyPlayed] = await Promise.all([
    collections.likedTracks(),
    collections.userPlaylists(),
    collections.recentlyPlayed(),
  ]);

  const [liked, playlists, played] = await Promise.all([
    likedTracks.countDocuments({ uid }),
    userPlaylists.countDocuments({ uid }),
    recentlyPlayed.countDocuments({ uid }),
  ]);

  return ok({ likedTracks: liked, playlists, recentlyPlayed: played });
});
