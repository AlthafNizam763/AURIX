import path from 'node:path';

import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(import.meta.dirname, './src'),
      '@components': path.resolve(import.meta.dirname, './components'),
    },
  },
  test: {
    environment: 'node',
    // The database-backed suites talk to the real cluster named in
    // `.env.local`. They are written to be safe against a live database —
    // every document they create is namespaced and removed — but they are not
    // instant, and Atlas is not local.
    testTimeout: 20_000,
    hookTimeout: 20_000,
    // One process. The Mongo client is a module-level singleton keyed on
    // `globalThis`; running files in parallel forks would open a pool per fork
    // for no benefit on a suite this size.
    pool: 'forks',
    // Vitest 4 moved the per-pool options to the top level.
    fileParallelism: false,
    setupFiles: ['./test/setup.ts'],
  },
});
