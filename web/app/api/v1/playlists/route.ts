import { collections } from '@/server/db/mongo';
import { created, ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { namedFields, playlistOut } from '@/server/services/playlists';
import { newPlaylistId } from '@/server/services/user-playlists';
import { log } from '@/server/utils/logger';

/** The user's own playlists: list them, create one. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth(async (_request, { auth }) => {
  const playlists = await collections.userPlaylists();
  const rows = await playlists
    .find({ uid: auth.uid })
    .sort({ updatedAt: -1 })
    .limit(500)
    .toArray();

  return ok({ playlists: rows.map(playlistOut) });
});

const createSchema = z.object({
  name: z.string().trim().min(1).max(200),
  description: z.string().trim().max(1000).default(''),
  coverUrl: S.url.default(''),
  source: z.string().trim().max(32).default('aurix'),
  sourceId: z.string().trim().max(220).nullish(),
  sourceUrl: S.url.nullish(),
});

export const POST = withAuth(async (request, { auth }) => {
  const input = await body(request, createSchema);

  const now = new Date();
  const playlistId = newPlaylistId();

  const playlists = await collections.userPlaylists();
  await playlists.insertOne({
    uid: auth.uid,
    playlistId,
    // `namedFields` writes the search index alongside the name. Writing the two
    // separately is how a rename leaves a playlist findable only by its old
    // title.
    ...namedFields(input.name),
    description: input.description,
    coverUrl: input.coverUrl,
    source: input.source,
    sourceId: input.sourceId ?? null,
    sourceUrl: input.sourceUrl ?? null,
    trackCount: 0,
    createdAt: now,
    updatedAt: now,
  });

  log.info(`Created playlist ${playlistId}`, 'playlists');
  return created({ id: playlistId });
});
