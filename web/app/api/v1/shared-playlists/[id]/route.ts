import { collections } from '@/server/db/mongo';
import { noContent, ok } from '@/server/http/respond';
import { S } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { playlistOut } from '@/server/services/playlists';
import { forbidden, notFound } from '@/server/utils/errors';

/** One shared playlist: read it, or remove what you imported. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth<{ id: string }>(async (_request, { params }) => {
  const id = S.docId.parse((await params).id);
  const playlists = await collections.globalPlaylists();
  // Readable by any signed-in user — that is what "shared" means here.
  return ok({ playlist: playlistOut(await playlists.findOne({ _id: id })) });
});

/**
 * Removes a playlist from the shared catalogue.
 *
 * The **one** place `importedByUserId` enforces rather than merely records. Only
 * the account that contributed a playlist may withdraw it; anyone else gets a
 * 403, because other people are listening to it.
 */
export const DELETE = withAuth<{ id: string }>(async (_request, { auth, params }) => {
  const id = S.docId.parse((await params).id);

  const playlists = await collections.globalPlaylists();
  const doc = await playlists.findOne({ _id: id }, { projection: { importedByUserId: 1 } });

  if (!doc) throw notFound('That playlist is no longer in the catalogue.');
  if (doc.importedByUserId !== auth.uid) {
    throw forbidden('Only the account that imported this playlist can remove it.');
  }

  const tracks = await collections.globalPlaylistTracks();
  await tracks.deleteMany({ playlistId: id });
  await playlists.deleteOne({ _id: id });

  return noContent();
});
