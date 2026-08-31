import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { positionBetween, rebalance } from '@/server/services/playlists';
import { scopeOf } from '@/server/services/user-playlists';
import { log } from '@/server/utils/logger';

/**
 * Moves one track within a playlist.
 *
 * ## Why a drag is one write
 *
 * `position` is a **double**, not an index. The new position is the midpoint
 * between the track's new neighbours, so moving a track in a 2,000-track
 * playlist updates exactly one row. With integer indices the same drag would
 * renumber everything after the insertion point.
 *
 * ## And why it occasionally is not
 *
 * Repeatedly dropping tracks into the same gap halves it each time, and after
 * enough subdivisions two adjacent positions are too close for a double to
 * separate. `positionBetween` detects that and returns `null`, and the whole
 * playlist is renumbered onto clean spacing — one write per track, rarely.
 *
 * The response says which happened. `{rebalanced: true}` tells the client its
 * cached positions are all stale and it should refetch; `{rebalanced: false,
 * position}` lets it patch the one row it already has. The Dart side branches on
 * exactly this, so the flag is part of the contract rather than a diagnostic.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  orderedTrackIds: z.array(S.docId).max(5000),
  from: z.number().int().min(0),
  to: z.number().int().min(0),
});

export const POST = withAuth<{ id: string }>(async (request, { auth, params }) => {
  const { id } = await params;
  const { orderedTrackIds, from, to } = await body(request, schema);

  if (from === to || from < 0 || from >= orderedTrackIds.length) {
    return ok({ rebalanced: false });
  }

  const scope = scopeOf(auth.uid, id);
  const tracks = await collections.userPlaylistTracks();
  const playlists = await collections.userPlaylists();

  const moved = orderedTrackIds[from]!;
  const reordered = orderedTrackIds.filter((_, index) => index !== from);
  const target = Math.max(0, Math.min(to, reordered.length));
  reordered.splice(target, 0, moved);

  const beforeId = target > 0 ? reordered[target - 1] : null;
  const afterId = target + 1 < reordered.length ? reordered[target + 1] : null;

  const positionOf = async (trackId: string | null | undefined): Promise<number | null> => {
    if (!trackId) return null;
    const row = await tracks.findOne({ ...scope, trackId }, { projection: { position: 1 } });
    return typeof row?.position === 'number' ? row.position : null;
  };

  const next = positionBetween(await positionOf(beforeId), await positionOf(afterId));

  if (next === null) {
    log.info(`Rebalancing playlist ${id} (${reordered.length} tracks)`, 'playlists');
    await rebalance(tracks, scope, reordered);
    await playlists.updateOne(
      { uid: auth.uid, playlistId: id },
      { $set: { updatedAt: new Date() } },
    );
    return ok({ rebalanced: true });
  }

  await tracks.updateOne({ ...scope, trackId: moved }, { $set: { position: next } });
  await playlists.updateOne(
    { uid: auth.uid, playlistId: id },
    { $set: { updatedAt: new Date() } },
  );

  return ok({ rebalanced: false, position: next });
});
