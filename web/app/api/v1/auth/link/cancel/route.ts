import { handler, noContent } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { discardGrant } from '@/server/services/oauth/flow';

/**
 * Abandons a pending account link.
 *
 * Deliberately unauthenticated and deliberately silent about whether the grant
 * existed: the token is the only thing being destroyed, and reporting "no such
 * grant" would let a caller probe which codes are live.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ linkToken: z.string().trim().min(1).max(512) });

export const POST = handler(async (request) => {
  const { linkToken } = await body(request, schema);
  await discardGrant(linkToken);
  return noContent();
});
