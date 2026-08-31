import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { songOut } from '@/server/services/catalog';

/**
 * One catalogue song.
 *
 * Answers `{song: null}` rather than 404 for an unknown id: the client asks
 * about ids it derived locally, and "not in the catalogue yet" is an ordinary
 * answer that prompts a contribution rather than an error to handle.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth<{ id: string }>(async (_request, { params }) => {
  const id = S.docId.parse((await params).id);
  const songs = await collections.catalogSongs();
  return ok({ song: songOut(await songs.findOne({ _id: id })) });
});
