import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { S, body } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';

/** One liked track: like it, unlike it, ask whether it is liked. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Likes a track.
 *
 * An upsert on `(uid, trackId)`, which is what makes liking idempotent — the
 * property `TrackKey` bought when the document id was derived from the track.
 * `$setOnInsert` on `createdAt` is the other half: liking a song that is already
 * liked must not move it to the top of the list. Both halves are load-bearing,
 * and the unique index is what makes the upsert safe under a race.
 */
export const PUT = withAuth<{ trackId: string }>(async (request, { auth, params }) => {
  const trackId = S.docId.parse((await params).trackId);
  const track = await body(request, S.track);

  const likedTracks = await collections.likedTracks();
  await likedTracks.updateOne(
    { uid: auth.uid, trackId },
    {
      $set: { ...track, uid: auth.uid, trackId, updatedAt: new Date() },
      $setOnInsert: { createdAt: new Date() },
    },
    { upsert: true },
  );

  return noContent();
});

export const DELETE = withAuth<{ trackId: string }>(async (_request, { auth, params }) => {
  const trackId = S.docId.parse((await params).trackId);
  const likedTracks = await collections.likedTracks();
  await likedTracks.deleteOne({ uid: auth.uid, trackId });
  return noContent();
});

export const GET = withAuth<{ trackId: string }>(async (_request, { auth, params }) => {
  const trackId = S.docId.parse((await params).trackId);
  const likedTracks = await collections.likedTracks();
  const found = await likedTracks.findOne(
    { uid: auth.uid, trackId },
    { projection: { _id: 1 } },
  );
  return ok({ liked: found !== null });
});
