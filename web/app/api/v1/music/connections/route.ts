import { ok } from '@/server/http/respond';
import { withAuth } from '@/server/middleware/auth';
import { connectionStatuses } from '@/server/services/music/connections';

/**
 * What the import screen renders above the URL field.
 *
 * ```
 * Spotify         ✓ Connected as althaf
 * YouTube Music   [ Connect YouTube ]
 * ```
 *
 * Carries **no token and no fragment of one** — only whether a connection
 * exists, whose account it is, and whether this deployment could make one. That
 * is the whole of what a client needs to draw the screen, and it is the most a
 * client should ever be told about a stored credential.
 *
 * `configured: false` means the deployment has no client id/secret for that
 * provider, and the button is shown disabled with the reason rather than
 * offered and then failing inside a browser tab.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAuth(async (_request, { auth }) =>
  ok({ connections: await connectionStatuses(auth.uid) }),
);
