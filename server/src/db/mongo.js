import { MongoClient, GridFSBucket } from 'mongodb';

import { env } from '../config/env.js';
import { log } from '../utils/logger.js';
import { COLLECTIONS, INDEXES, GRIDFS_BUCKET } from './collections.js';

/**
 * The one MongoDB connection in the process.
 *
 * ## Why a module-level singleton rather than a client per request
 *
 * The driver's `MongoClient` *is* the connection pool. Constructing one per
 * request would open a fresh pool — and a fresh TLS handshake and SRV lookup —
 * every time, which on Atlas costs hundreds of milliseconds and exhausts the
 * cluster's connection limit under trivial load. One client, shared, is what
 * the driver is designed for and what every read and write here goes through.
 *
 * ## Connecting is idempotent
 *
 * [connect] can be called from anywhere and any number of times; the second
 * call awaits the first one's promise rather than racing it. Serverless hosts
 * re-enter the module on a warm start and would otherwise open a second pool
 * on every invocation.
 */

let client = null;
let db = null;
let connecting = null;

export async function connect() {
  if (db) return db;
  if (connecting) return connecting;

  connecting = (async () => {
    client = new MongoClient(env.mongoUri, {
      // Bounded so a burst of traffic cannot exhaust the Atlas tier's
      // connection allowance; 10 is comfortably above what a single app
      // instance needs, since every handler here is short-lived.
      maxPoolSize: 10,
      minPoolSize: 1,
      // Fail fast rather than hanging a request for the driver's 30s default.
      // A caller that gets an error in 8 seconds can retry; one that is still
      // waiting at 30 has already lost the user.
      serverSelectionTimeoutMS: 8000,
      connectTimeoutMS: 10000,
      retryWrites: true,
      retryReads: true,
    });

    await client.connect();
    db = client.db(env.dbName);
    log.info(`MongoDB connected — database "${env.dbName}"`, 'db');
    return db;
  })();

  try {
    return await connecting;
  } catch (error) {
    // Clear the memo so a later call can retry instead of re-awaiting a
    // permanently rejected promise.
    connecting = null;
    client = null;
    db = null;
    throw error;
  }
}

/**
 * The database handle. Throws rather than lazily connecting, because a handler
 * that reaches this before `connect()` has resolved is a boot-order bug, and a
 * silent lazy connect would hide it behind a slow first request.
 */
export function getDb() {
  if (!db) {
    throw new Error('MongoDB is not connected yet — call connect() during boot.');
  }
  return db;
}

/** A typed accessor per collection, so no route spells a collection name. */
export const collections = {
  users: () => getDb().collection(COLLECTIONS.users),
  identities: () => getDb().collection(COLLECTIONS.identities),
  refreshTokens: () => getDb().collection(COLLECTIONS.refreshTokens),
  actionTokens: () => getDb().collection(COLLECTIONS.actionTokens),
  otpCodes: () => getDb().collection(COLLECTIONS.otpCodes),
  otpSends: () => getDb().collection(COLLECTIONS.otpSends),
  authStates: () => getDb().collection(COLLECTIONS.authStates),
  authGrants: () => getDb().collection(COLLECTIONS.authGrants),
  likedTracks: () => getDb().collection(COLLECTIONS.likedTracks),
  recentlyPlayed: () => getDb().collection(COLLECTIONS.recentlyPlayed),
  userPlaylists: () => getDb().collection(COLLECTIONS.userPlaylists),
  userPlaylistTracks: () => getDb().collection(COLLECTIONS.userPlaylistTracks),
  catalogSongs: () => getDb().collection(COLLECTIONS.catalogSongs),
  globalPlaylists: () => getDb().collection(COLLECTIONS.globalPlaylists),
  globalPlaylistTracks: () => getDb().collection(COLLECTIONS.globalPlaylistTracks),
  appConfig: () => getDb().collection(COLLECTIONS.appConfig),
};

/** The GridFS bucket that holds uploaded logos and fonts. */
export function brandAssets() {
  return new GridFSBucket(getDb(), { bucketName: GRIDFS_BUCKET });
}

/**
 * Creates every index the API's queries depend on.
 *
 * Run at boot and again by `npm run indexes`. `createIndexes` is idempotent —
 * an index that already exists with the same key and options is a no-op — so
 * this is safe on every start.
 *
 * The uniqueness constraints here are not optimisations, they are the schema:
 * `(uid, trackId)` unique on liked tracks is what makes liking the same song
 * twice a single row, which is what the Firestore document-id-derived-from-key
 * design bought before the migration. Losing it would let duplicates back in.
 */
export async function ensureIndexes() {
  const results = [];
  for (const [name, specs] of Object.entries(INDEXES)) {
    if (specs.length === 0) continue;
    const collection = getDb().collection(COLLECTIONS[name]);
    try {
      const created = await collection.createIndexes(specs);
      results.push(`${COLLECTIONS[name]}:${created.length}`);
    } catch (error) {
      // 85 IndexOptionsConflict / 86 IndexKeySpecsConflict: an index of this
      // name already exists with *different* options. That is what a spec
      // change looks like from here, and it is a real one — `users.email`
      // became sparse when phone sign-in arrived, because an account created
      // from a phone number has no email field and a non-sparse unique index
      // permits exactly one document that is missing it.
      //
      // Mongo will not alter an index in place, so the only way forward is
      // drop-and-recreate. It is done here rather than in a migration script
      // because a deployment that boots against the old index does not merely
      // run slowly — it refuses the second phone registration with a
      // duplicate-key error nobody would connect to an index definition.
      //
      // The window in which the unique constraint is absent is the length of
      // one createIndex on the same connection. Said out loud in the log so a
      // deployment that sees it knows what happened.
      if (error?.code === 85 || error?.code === 86) {
        log.warn(
          `Index definitions on ${COLLECTIONS[name]} have changed — rebuilding: ${error.message}`,
          'db',
        );
        try {
          for (const spec of specs) {
            await collection.dropIndex(spec.name).catch(() => {});
          }
          const created = await collection.createIndexes(specs);
          results.push(`${COLLECTIONS[name]}:${created.length}*`);
          continue;
        } catch (retryError) {
          log.error(
            `Could not rebuild indexes on ${COLLECTIONS[name]}`,
            'db',
            retryError,
          );
          continue;
        }
      }

      // Anything else is a deployment concern, not a reason to refuse to
      // serve traffic. Say so loudly and carry on.
      log.warn(
        `Could not create indexes on ${COLLECTIONS[name]}: ${error.message}`,
        'db',
      );
    }
  }
  log.info(`Indexes ensured — ${results.join(' ')}`, 'db');
}

export async function close() {
  if (client) {
    await client.close();
    client = null;
    db = null;
    connecting = null;
    log.info('MongoDB connection closed', 'db');
  }
}

/** Liveness probe for `/health`. Cheap — one admin command, no collection scan. */
export async function ping() {
  if (!db) return false;
  try {
    await db.command({ ping: 1 });
    return true;
  } catch {
    return false;
  }
}
