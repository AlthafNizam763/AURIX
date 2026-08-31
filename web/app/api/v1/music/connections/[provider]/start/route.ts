import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { beginConnect } from '@/server/services/music/connections';

/**
 * Opens a provider consent round trip and returns the URL to open.
 *
 * `withAuth`, not `withOptionalAuth`: a connection is filed against an AURIX
 * account, so there has to be one. The uid is taken from the verified token here
 * and written into the state document, which is what stops the callback — the
 * one hop an attacker can influence — from choosing whose account a Spotify
 * authorization lands on.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  /** Where the browser is sent once the connection is stored. Allow-listed. */
  redirectUri: z.string().trim().min(3).max(2048),
});

export const POST = withAuth<{ provider: string }>(async (request, { auth, params }) => {
  const headers = await enforce(LIMITS.oauthStart, request);
  const input = await body(request, schema);
  const { provider } = await params;

  const flow = await beginConnect({
    uid: auth.uid,
    provider,
    redirectUri: input.redirectUri,
  });

  return ok(flow, 200, headers);
});
