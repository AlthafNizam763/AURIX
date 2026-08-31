import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { playlistOut } from '@/server/services/playlists';
import { SEARCH_FANOUT } from '@/server/services/shared-playlists';
import { limitOf } from '@/server/utils/json';
import { matchesResidual, normaliseAlbum, queryToken, residualWords } from '@/server/utils/search';

/**
 * Searches the shared catalogue by playlist name.
 *
 * ## How the search works, and why it is shaped this way
 *
 * One indexed lookup on the **longest** word of the query — the most selective
 * one — then the remaining words are checked over the bounded result page. That
 * is inherited from Firestore, where one `array-contains` per query was a hard
 * limit, and it is kept deliberately: Mongo would allow `$all` over every word,
 * but `$all` requires every word to be a token, so a query whose second word is
 * a stop word would return nothing where it previously returned results. Same
 * query, same results, different database.
 *
 * `SEARCH_FANOUT` widens the page when there are residual words to apply, so
 * filtering does not empty a page that had matches further down it.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  q: z.string().max(200).default(''),
  limit: z.string().optional(),
});

export const GET = withAuth(async (request) => {
  const { q, limit: rawLimit } = query(request, schema);
  const limit = limitOf(rawLimit, { fallback: 20, max: 100 });

  const token = queryToken(q);
  if (!token) return ok({ playlists: [] });

  const residual = residualWords(q);
  const playlists = await collections.globalPlaylists();

  const rows = await playlists
    .find({ searchTokens: token })
    .limit(residual.length === 0 ? limit * 2 : limit * SEARCH_FANOUT)
    .toArray();

  const wanted = normaliseAlbum(q);
  const matched = rows.filter((row) =>
    matchesResidual(row.searchTitle ?? normaliseAlbum(row.name ?? ''), residual),
  );

  // Exact title first, then prefix, then the rest; ties broken by size, because
  // a 200-track playlist is more likely what someone meant than a 3-track one
  // with the same name.
  const score = (row: { searchTitle?: string; name?: string }) => {
    const title = row.searchTitle ?? normaliseAlbum(row.name ?? '');
    if (title === wanted) return 0;
    if (title.startsWith(wanted)) return 1;
    return 2;
  };

  matched.sort((a, b) => score(a) - score(b) || (b.trackCount ?? 0) - (a.trackCount ?? 0));

  return ok({ playlists: matched.slice(0, limit).map(playlistOut) });
});
