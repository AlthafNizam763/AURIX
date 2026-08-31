import { collections } from '@/server/db/mongo';
import { created, ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { namedFields } from '@/server/services/playlists';
import { log } from '@/server/utils/logger';

/**
 * Adds a playlist to the shared catalogue, or refreshes one already there.
 *
 * ## Why the id comes from the client
 *
 * `_id` is derived from the source and its id (`PlaylistKey` on the Dart side),
 * so two people importing the same Spotify playlist land on the *same document*
 * rather than creating two. That is the whole point of the shared catalogue —
 * the second importer contributes to what the first added instead of duplicating
 * it.
 *
 * It also means the create is an upsert, and the branch below is what keeps it
 * honest: only the account that first imported a playlist may change its name or
 * cover. A later importer refreshes nothing, because otherwise the title every
 * user sees would be decided by whoever synced most recently.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  id: S.docId,
  source: z.string().trim().min(1).max(32),
  sourceId: z.string().trim().min(1).max(220),
  name: z.string().trim().max(200).default(''),
  description: z.string().trim().max(1000).default(''),
  coverUrl: S.url.default(''),
  sourceUrl: S.url.nullish(),
  importedBy: z.string().trim().max(120).default(''),
});

export const POST = withAuth(async (request, { auth }) => {
  const input = await body(request, schema);
  const { id, source, sourceId, name, description, coverUrl, sourceUrl, importedBy } = input;
  const { uid } = auth;
  const now = new Date();

  const playlists = await collections.globalPlaylists();

  const existing = await playlists.findOne(
    { _id: id },
    { projection: { importedByUserId: 1 } },
  );

  if (existing) {
    const isImporter = existing.importedByUserId === uid;
    const $set: Record<string, unknown> = { updatedAt: now };
    if (isImporter) {
      if (name.trim()) Object.assign($set, namedFields(name));
      if (coverUrl) $set.coverUrl = coverUrl;
      if (sourceUrl) $set.sourceUrl = sourceUrl;
    }
    await playlists.updateOne({ _id: id }, { $set });
    log.info(`Existing shared playlist ${id}${isImporter ? ' refreshed' : ''}`, 'import');
    return ok({ id, created: false });
  }

  await playlists.updateOne(
    { _id: id },
    {
      $set: { updatedAt: now },
      $setOnInsert: {
        ...namedFields(name),
        description,
        coverUrl,
        source,
        sourceId,
        sourceUrl: sourceUrl ?? '',
        trackCount: 0,
        importedByUserId: uid,
        importedBy,
        importedAt: now,
        createdAt: now,
      },
    },
    { upsert: true },
  );

  log.info(`Created shared playlist ${id}`, 'import');
  return created({ id, created: true });
});
