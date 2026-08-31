import { ok } from '@/server/http/respond';
import { body, deviceField, z } from '@/server/http/validate';
import { withOptionalAuth } from '@/server/middleware/auth';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { beginFlow } from '@/server/services/oauth/flow';
import { unauthorized } from '@/server/utils/errors';

/**
 * Opens a browser transaction and returns the URL to put in front of the user.
 *
 * `intent: 'link'` requires a session, and the account being linked to is baked
 * into the stored state here — so it is decided by the token on *this* request
 * and cannot be influenced by anything that comes back from the browser.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  redirectUri: z.string().trim().min(3).max(2048),
  intent: z.enum(['signIn', 'link']).default('signIn'),
  device: deviceField,
});

export const POST = withOptionalAuth<{ provider: string }>(
  async (request, { auth, params }) => {
    const headers = await enforce(LIMITS.oauthStart, request);
    const input = await body(request, schema);
    const { provider } = await params;

    if (input.intent === 'link' && !auth?.uid) throw unauthorized();

    const flow = await beginFlow({
      providerId: provider,
      redirectUri: input.redirectUri,
      intent: input.intent,
      actorUid: auth?.uid,
      device: input.device,
    });

    return ok(flow, 200, headers);
  },
);
