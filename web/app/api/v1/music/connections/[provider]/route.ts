import { noContent } from '@/server/http/respond';
import { withAuth } from '@/server/middleware/auth';
import { disconnect } from '@/server/services/music/connections';
import { isMusicProviderId } from '@/server/services/music/providers';
import { notFound } from '@/server/utils/errors';

/**
 * "Disconnect Spotify" / "Disconnect YouTube".
 *
 * Forgets AURIX's copy of the tokens. It does **not** revoke the grant at the
 * provider, and that is the correct scope: the user asked AURIX to forget them,
 * and a central revocation would also sign out any other device using the same
 * provider account. Both providers offer a full revocation on their own
 * security pages, which is where that belongs.
 *
 * Idempotent — 204 whether or not there was anything to remove, because
 * "disconnect something already disconnected" is a success from the caller's
 * point of view and a 404 would only make the client handle a case it cannot
 * act on.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const DELETE = withAuth<{ provider: string }>(async (_request, { auth, params }) => {
  const { provider } = await params;
  if (!isMusicProviderId(provider)) throw notFound('No such music provider.');

  await disconnect(auth.uid, provider);
  return noContent();
});
