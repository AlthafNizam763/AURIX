import type { Filter } from 'mongodb';

import type { UserDoc } from '@/server/db/documents';
import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { query, z } from '@/server/http/validate';
import { withAdmin } from '@/server/middleware/auth';
import { accountViews } from '@/server/services/users';
import { limitOf } from '@/server/utils/json';

/** The account list, searchable by the start of an address or a name. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  q: z.string().trim().max(200).optional(),
  limit: z.string().optional(),
});

/**
 * Escapes a user string for use inside a `$regex`.
 *
 * Not optional. An unescaped user string in a regex is a denial of service
 * waiting to happen — `(a+)+$` against a long field is the classic catastrophic
 * backtracking case — and the anchor below is what lets the query use an index
 * at all instead of scanning every account.
 */
function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export const GET = withAdmin(async (request) => {
  const { q: search, limit } = query(request, schema);

  const filter: Filter<UserDoc> = search
    ? {
        $or: [
          { email: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
          { name: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
        ],
      }
    : {};

  const users = await collections.users();
  const rows = await users
    .find(filter)
    .sort({ createdAt: -1 })
    .limit(limitOf(limit, { fallback: 50, max: 200 }))
    .toArray();

  // Batched: two queries rather than 2N, because each account's linked
  // providers live in a separate collection.
  return ok({ users: await accountViews(rows) });
});
