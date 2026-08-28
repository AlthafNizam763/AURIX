/**
 * Grants administrator rights to an existing account.
 *
 *   npm run make-admin -- someone@example.com
 *
 * The escape hatch for the two cases the API cannot cover: the first admin on a
 * deployment where BOOTSTRAP_ADMIN_EMAIL was never set, and an account locked
 * out because the last administrator was deleted. Everything else should go
 * through `POST /api/v1/admin/users/:uid/admin`, which leaves an audit line.
 */
import { close, collections, connect } from '../src/db/mongo.js';
import { log } from '../src/utils/logger.js';

const email = process.argv[2]?.trim().toLowerCase();

if (!email) {
  console.error('Usage: npm run make-admin -- someone@example.com');
  process.exit(1);
}

try {
  await connect();
  const result = await collections
    .users()
    .findOneAndUpdate(
      { email },
      { $set: { isAdmin: true, updatedAt: new Date() } },
      { returnDocument: 'after' },
    );

  if (!result) {
    log.error(`No account for ${email}. Register in the app first, then run this.`, 'admin');
    process.exitCode = 1;
  } else {
    log.info(`${email} (${result.uid}) is now an administrator.`, 'admin');
  }
} catch (error) {
  log.error('Could not grant admin', 'admin', error);
  process.exitCode = 1;
} finally {
  await close();
}
