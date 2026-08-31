import { handler, noContent } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { revokeRefreshToken } from '@/server/services/tokens';

/**
 * Ends one session.
 *
 * Unauthenticated on purpose: the refresh token in the body *is* the credential,
 * and a client whose access token has already expired must still be able to sign
 * out. Revoking an unknown token is a no-op rather than an error, so a
 * double-tap on Sign Out does not produce a failure the user has to read.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ refreshToken: z.string().min(1).optional() });

export const POST = handler(async (request) => {
  const { refreshToken } = await body(request, schema);
  await revokeRefreshToken(refreshToken);
  return noContent();
});
