import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { songOut } from '@/server/services/catalog';
import { limitOf } from '@/server/utils/json';
import { matchesResidual, normaliseAlbum, queryToken, residualWords } from '@/server/utils/search';

/**
 * Searches the shared song catalogue.
 *
 * The same index-plus-residual shape as the playlist search: one lookup on the
 * longest word, then the remaining words applied over a bounded page. Here the
 * haystack is built from the title, artists and album together, so a query
 * spanning two of them still matches.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/** Candidates fetched per result when residual words have to be applied. */
const SEARCH_FANOUT = 4;

const schema = z.object({
  q: z.string().max(200).default(''),
  limit: z.string().optional(),
});

export const GET = withAuth(async (request) => {
  const { q, limit: rawLimit } = query(request, schema);
  const limit = limitOf(rawLimit, { fallback: 20, max: 100 });

  const token = queryToken(q);
  if (!token) return ok({ songs: [] });

  const residual = residualWords(q);
  const songs = await collections.catalogSongs();

  const rows = await songs
    .find({ searchTokens: token })
    .limit(residual.length === 0 ? limit : limit * SEARCH_FANOUT)
    .toArray();

  const out = [];
  for (const row of rows) {
    const haystack = normaliseAlbum(
      `${row.title ?? ''} ${(row.artists ?? []).join(', ')} ${row.album ?? ''}`,
    );
    if (!matchesResidual(haystack, residual)) continue;
    out.push(songOut(row));
    if (out.length >= limit) break;
  }

  return ok({ songs: out });
});
