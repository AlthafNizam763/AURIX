import { handler, ok } from '@/server/http/respond';
import { readTheme } from '@/server/services/theme';
import { iso } from '@/server/utils/json';

/**
 * The theme's version, and nothing else.
 *
 * The client caches the config it last applied and renders from that cache on
 * launch, so a cold start never blocks on the network. This is what it polls to
 * find out whether the cache is stale — a few bytes instead of the whole
 * palette, on a request made by every install.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = handler(async () => {
  const theme = await readTheme();
  return ok({ version: theme.version ?? 1, updatedAt: iso(theme.updatedAt) });
});
