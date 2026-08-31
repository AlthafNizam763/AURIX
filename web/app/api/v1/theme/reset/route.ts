import { ok } from '@/server/http/respond';
import { withAdmin } from '@/server/middleware/auth';
import { resetTheme, themeOut } from '@/server/services/theme';
import { log } from '@/server/utils/logger';

/**
 * Restores the shipped AURIX identity.
 *
 * The version keeps climbing rather than returning to 1 — it is a cache key, and
 * a client holding version 7 must see 8 and refetch, not see 1 and conclude
 * nothing has changed.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const POST = withAdmin(async (_request, { auth }) => {
  const theme = await resetTheme({ uid: auth.uid });
  log.info(`Theme reset to defaults by ${auth.uid}`, 'theme');
  return ok({ theme: themeOut(theme) });
});
