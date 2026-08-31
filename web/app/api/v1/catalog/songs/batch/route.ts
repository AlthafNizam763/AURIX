import type { Document } from 'mongodb';

import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { songOut } from '@/server/services/catalog';

/**
 * Looks up many songs at once.
 *
 * **Answers a map keyed by id, not an array** — the client resolves a playlist's
 * rows against it by key, and a map means no scan per track. Ids that do not
 * exist are simply absent from the map rather than being null entries.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ ids: z.array(S.docId).max(2000) });

export const POST = withAuth(async (request) => {
  const { ids: raw } = await body(request, schema);
  const ids = [...new Set(raw)];
  if (ids.length === 0) return ok({ songs: {} });

  const songs = await collections.catalogSongs();
  const rows = await songs.find({ _id: { $in: ids } }).toArray();

  const out: Record<string, Document | null> = {};
  for (const row of rows) out[String(row._id)] = songOut(row);

  return ok({ songs: out });
});
