import type { AnyBulkWriteOperation } from 'mongodb';

import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import type { CatalogSongDoc } from '@/server/db/documents';
import { mergeDelta, preferRicher, songIn } from '@/server/services/catalog';
import { log } from '@/server/utils/logger';

/**
 * Contributes songs to the shared catalogue.
 *
 * **A merge, not an overwrite.** See `services/catalog` for why: the same song
 * arrives from different sources carrying different metadata, and a write that
 * replaced the stored row would make the catalogue's completeness depend on
 * whoever imported most recently.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ songs: z.array(songIn).max(2000) });

export const POST = withAuth(async (request) => {
  const { songs: incoming } = await body(request, schema);
  if (incoming.length === 0) return ok({ written: 0, created: 0, updated: 0 });

  // Collapse duplicates *within the batch* first. Two upserts on one key inside
  // a single `bulkWrite` race each other for the same row.
  const byId = new Map<string, (typeof incoming)[number]>();
  for (const song of incoming) {
    const seen = byId.get(song.id);
    byId.set(song.id, seen ? preferRicher(seen, song) : song);
  }

  const ids = [...byId.keys()];
  const songs = await collections.catalogSongs();
  const existingRows = await songs.find({ _id: { $in: ids } }).toArray();
  const existing = new Map(existingRows.map((row) => [row._id, row]));

  const now = new Date();
  const operations: AnyBulkWriteOperation<CatalogSongDoc>[] = [];
  let createdCount = 0;
  let updatedCount = 0;

  for (const song of byId.values()) {
    const current = existing.get(song.id);

    if (!current) {
      const { id, ...rest } = song;
      operations.push({
        updateOne: {
          filter: { _id: id },
          update: { $set: { ...rest, updatedAt: now }, $setOnInsert: { createdAt: now } },
          upsert: true,
        },
      });
      createdCount++;
      continue;
    }

    const delta = mergeDelta(song, current);
    // Nothing to add. Writing anyway would churn `updatedAt` on every import
    // and make the `updatedAt` index useless for finding what actually changed.
    if (Object.keys(delta).length === 0) continue;

    operations.push({
      updateOne: {
        filter: { _id: song.id },
        update: { $set: { ...delta, updatedAt: now } },
      },
    });
    updatedCount++;
  }

  // Unordered: the operations touch distinct keys, so concurrency is safe and
  // materially faster on a long import.
  if (operations.length > 0) await songs.bulkWrite(operations, { ordered: false });

  log.info(
    `Catalogue: ${createdCount} new, ${updatedCount} improved, ` +
      `${byId.size - createdCount - updatedCount} unchanged`,
    'catalog',
  );

  return ok({ written: createdCount + updatedCount, created: createdCount, updated: updatedCount });
});
