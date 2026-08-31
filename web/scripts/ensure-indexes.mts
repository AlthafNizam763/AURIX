/**
 * Creates every index the API's queries depend on.
 *
 *     npm run indexes
 *
 * ## Why this is a script rather than something the API does on start
 *
 * The Express server ran `ensureIndexes()` during boot, before it accepted a
 * request. Serverless has no boot, and doing it per request would add a round
 * trip to every cold invocation for a result that is almost always "nothing to
 * do" — and would let the drop-and-recreate path race across instances on live
 * traffic.
 *
 * **This is a required deployment step, not an optimisation.** The uniqueness
 * constraints are the schema: `(uid, trackId)` on liked tracks is what makes
 * liking the same song twice one row rather than two, and `(provider, subject)`
 * on identities is what stops one Google account being attached to two AURIX
 * users. A deployment that skips this does not run slowly — it accumulates
 * duplicates that no later index can remove.
 *
 * Run it once against each environment, and again whenever an index definition
 * in `src/server/db/collections.ts` changes.
 */

// Marks this file a module, which is what permits top-level `await` and keeps
// its bindings out of the global scope.
export {};

// Next.js loads `.env.local` for the application, but a standalone script gets
// no such help — hence doing it explicitly, before anything reads `env`.
// Absent is not an error: on a deployment the values come from the platform's
// environment rather than a file.
for (const file of ['.env.local', '.env']) {
  try {
    process.loadEnvFile(file);
  } catch {
    // No such file. Fine.
  }
}

const { debugSummary, missingRequired } = await import('../src/server/config/env');

const missing = missingRequired();
if (missing.length > 0) {
  console.error(
    `Cannot connect: missing ${missing.join(', ')}.\n` +
      'Set them in web/.env.local, or run this with the deployment environment loaded.',
  );
  process.exit(1);
}

// `close` is renamed because it collides with the DOM `close` global that the
// project's lib includes for the browser half of the codebase.
const { close: closeMongo, ensureIndexes } = await import('../src/server/db/mongo');

console.log(`AURIX indexes — ${debugSummary()}`);

try {
  await ensureIndexes();
  console.log('Done.');
} catch (error) {
  console.error('Could not ensure indexes:', error instanceof Error ? error.message : error);
  process.exitCode = 1;
} finally {
  await closeMongo();
}
