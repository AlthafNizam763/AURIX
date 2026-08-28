/**
 * Creates every index the API depends on, then exits.
 *
 * The server does this at boot too. This script exists for the deployment that
 * runs migrations as a separate step, and for the case where boot-time index
 * creation was skipped because it conflicted with an existing definition — the
 * warning names the collection, and this is what you run after fixing it.
 *
 *   npm run indexes
 */
import { close, connect, ensureIndexes } from '../src/db/mongo.js';
import { log } from '../src/utils/logger.js';

try {
  await connect();
  await ensureIndexes();
  log.info('Done.', 'indexes');
} catch (error) {
  log.error('Could not create indexes', 'indexes', error);
  process.exitCode = 1;
} finally {
  await close();
}
