import dns from 'node:dns';

import { createApp } from './app.js';
import { debugSummary, env } from './config/env.js';
import { close, connect, ensureIndexes } from './db/mongo.js';
import { readTheme } from './services/theme.js';
import { log } from './utils/logger.js';

/**
 * Boot.
 *
 * The order is deliberate and mirrors `bootstrap()` in the Flutter app:
 * everything that must be true before the first request is awaited here, and
 * nothing that can wait is. A server that accepts a request before its indexes
 * exist will answer it with a collection scan, which is slow enough on a cold
 * Atlas tier to look like an outage.
 */
async function main() {
  log.info(`Starting AURIX API — ${debugSummary()}`, 'boot');

  // Before anything resolves a hostname. See `env.dnsServers` for why this
  // exists; in short, `mongodb+srv://` needs an SRV lookup and some networks
  // answer A records while refusing SRV.
  if (env.dnsServers.length > 0) {
    dns.setServers(env.dnsServers);
    log.info(`DNS overridden — ${env.dnsServers.join(', ')}`, 'boot');
  }

  if (env.isProduction && env.corsOrigins.length === 0) {
    log.warn(
      'CORS_ORIGINS is empty in production — every origin will be reflected. ' +
        'Set it to the origins that should be allowed to call this API.',
      'boot',
    );
  }
  if (env.isProduction && !env.mailEnabled) {
    log.warn(
      'No SMTP configured in production — password-reset and verification emails ' +
        'cannot be delivered, and the reset token is NOT returned in the response.',
      'boot',
    );
  }

  await connect();
  await ensureIndexes();

  // Seeds the default theme document on a fresh database, so the very first
  // client to launch gets the AURIX identity rather than a 404 it has to
  // recover from.
  const theme = await readTheme();
  log.info(`Theme ready — version ${theme.version ?? 1}`, 'boot');

  const app = createApp();
  const server = app.listen(env.port, env.host, () => {
    log.info(`Listening on http://${env.host}:${env.port}`, 'boot');
    log.info(`Admin panel at http://localhost:${env.port}/admin/`, 'boot');
  });

  // Graceful shutdown. Without it a redeploy drops in-flight requests and
  // leaves Atlas holding connections until they time out.
  const shutdown = async (signal) => {
    log.info(`${signal} received — shutting down`, 'boot');
    server.close(async () => {
      await close();
      process.exit(0);
    });
    // A request that has not finished in ten seconds is not going to.
    setTimeout(() => process.exit(1), 10_000).unref();
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((error) => {
  log.error('AURIX API failed to start', 'boot', error);
  process.exit(1);
});
