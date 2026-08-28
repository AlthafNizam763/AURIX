/**
 * Writes the default theme document, without starting a server.
 *
 *   npm run seed
 *
 * Idempotent: `readTheme` upserts with `$setOnInsert`, so running it against a
 * database whose theme has been customised prints the current version and
 * changes nothing.
 */
import { close, connect, ensureIndexes } from '../src/db/mongo.js';
import { readTheme } from '../src/services/theme.js';
import { log } from '../src/utils/logger.js';

try {
  await connect();
  await ensureIndexes();
  const theme = await readTheme();
  log.info(`Theme document ready — version ${theme.version ?? 1}`, 'seed');
} catch (error) {
  log.error('Seed failed', 'seed', error);
  process.exitCode = 1;
} finally {
  await close();
}
