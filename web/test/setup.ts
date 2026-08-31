/**
 * Loads the same environment the application does.
 *
 * Next.js reads `.env.local` itself; Vitest does not, so the database-backed
 * suites would otherwise run against no configuration and report a missing
 * `MONGODB_URI` rather than the thing under test.
 *
 * Absent is not an error — the pure suites need nothing — but the suites that
 * do need a database skip themselves when it is missing rather than failing,
 * so that `npm test` is still meaningful on a machine with no credentials.
 */
for (const file of ['.env.local', '.env']) {
  try {
    process.loadEnvFile(file);
  } catch {
    // No such file. Fine.
  }
}
