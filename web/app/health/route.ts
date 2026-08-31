import { ping } from '@/server/db/mongo';

/**
 * Liveness probe.
 *
 * Deliberately outside `/api/v1` — it reports on this deployment, not on a
 * version of the API, so it must not move when the API version does.
 *
 * 503 when the database is unreachable, so an uptime monitor treats a live
 * process with a dead database as the outage it is rather than as healthy.
 */

// The Mongo driver is a native Node consumer and cannot run on the Edge
// runtime. Every route that touches the database declares this.
export const runtime = 'nodejs';

// Never cached, never prerendered. A cached health check is not a health check,
// and without this Next would try to evaluate it at build time — when there is
// legitimately no database to reach.
export const dynamic = 'force-dynamic';

export async function GET() {
  const db = await ping();

  return Response.json(
    {
      ok: db,
      service: 'aurix-api',
      db: db ? 'up' : 'down',
      // The Express version reported `process.uptime()`. It is meaningless on
      // serverless — it measures how long this particular instance has been
      // warm, which is an accident of traffic rather than a property of the
      // deployment. The commit is what someone reading a health check actually
      // wants to know, and Vercel supplies it.
      commit: process.env.VERCEL_GIT_COMMIT_SHA?.slice(0, 7) ?? 'local',
    },
    { status: db ? 200 : 503 },
  );
}
