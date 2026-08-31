import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { withAdmin } from '@/server/middleware/auth';

/** A database overview for the dashboard. Six counts, run together. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAdmin(async () => {
  const [users, likedTracks, userPlaylists, globalPlaylists, catalogSongs] = await Promise.all([
    collections.users(),
    collections.likedTracks(),
    collections.userPlaylists(),
    collections.globalPlaylists(),
    collections.catalogSongs(),
  ]);

  const [total, admins, liked, playlists, sharedPlaylists, songs] = await Promise.all([
    users.countDocuments(),
    users.countDocuments({ isAdmin: true }),
    likedTracks.countDocuments(),
    userPlaylists.countDocuments(),
    globalPlaylists.countDocuments(),
    catalogSongs.countDocuments(),
  ]);

  return ok({ users: total, admins, likedTracks: liked, playlists, sharedPlaylists, songs });
});
