import { after } from 'next/server';

import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { S, body, query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { trackOut } from '@/server/services/playlists';
import { iso, limitOf } from '@/server/utils/json';
import { log } from '@/server/utils/logger';

/** Play history — read it, add to it, clear it. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Rows kept per user. Older entries are trimmed after each write. */
const HISTORY_LIMIT = 200;

const readSchema = z.object({ limit: z.string().optional() });

export const GET = withAuth(async (request, { auth }) => {
  const { limit } = query(request, readSchema);
  const recentlyPlayed = await collections.recentlyPlayed();

  const rows = await recentlyPlayed
    .find({ uid: auth.uid })
    .sort({ playedAt: -1 })
    .limit(limitOf(limit, { fallback: 50, max: HISTORY_LIMIT }))
    .toArray();

  return ok({
    entries: rows.map((row) => ({
      ...trackOut(row),
      playedAt: iso(row.playedAt),
      position: row.position ?? 0,
    })),
  });
});

const writeSchema = z.object({
  trackId: S.docId,
  track: S.track,
  position: z.number().int().min(0).default(0),
});

export const POST = withAuth(async (request, { auth }) => {
  const { trackId, track, position } = await body(request, writeSchema);
  const { uid } = auth;

  const recentlyPlayed = await collections.recentlyPlayed();
  await recentlyPlayed.updateOne(
    { uid, itemId: trackId },
    {
      $set: {
        ...track,
        uid,
        itemId: trackId,
        trackId,
        playedAt: new Date(),
        position,
        duration: track.durationMs ?? 0,
      },
      $setOnInsert: { createdAt: new Date() },
    },
    { upsert: true },
  );

  // Trimming is housekeeping: the row the user cares about is already written,
  // and a failure here is logged rather than surfaced.
  //
  // `after()` rather than a floating promise. On the Express server the event
  // loop kept running after the response and the trim completed on its own; a
  // serverless instance can be frozen the moment the response is returned, so
  // detached work must be handed to the platform or it silently never runs —
  // and history would grow without bound.
  after(async () => {
    try {
      await trim(uid);
    } catch (error) {
      log.debug(`History trim failed: ${(error as Error).message}`, 'library');
    }
  });

  return noContent();
});

export const DELETE = withAuth(async (_request, { auth }) => {
  const recentlyPlayed = await collections.recentlyPlayed();
  await recentlyPlayed.deleteMany({ uid: auth.uid });
  return noContent();
});

async function trim(uid: string): Promise<void> {
  const recentlyPlayed = await collections.recentlyPlayed();

  const total = await recentlyPlayed.countDocuments({ uid });
  if (total <= HISTORY_LIMIT) return;

  const excess = await recentlyPlayed
    .find({ uid }, { projection: { _id: 1 } })
    .sort({ playedAt: -1 })
    .skip(HISTORY_LIMIT)
    .toArray();

  if (excess.length === 0) return;
  await recentlyPlayed.deleteMany({ _id: { $in: excess.map((row) => row._id) } });
}
