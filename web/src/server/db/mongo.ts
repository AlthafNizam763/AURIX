import dns from 'node:dns';

import { GridFSBucket, MongoClient, type Collection, type Db, type Document } from 'mongodb';

import { assertConfigured, env } from '../config/env';
import { log } from '../utils/logger';
import { COLLECTIONS, GRIDFS_BUCKET, INDEXES, type CollectionKey } from './collections';
import type {
  ActionTokenDoc,
  AppConfigDoc,
  AuthGrantDoc,
  AuthStateDoc,
  CatalogSongDoc,
  GlobalPlaylistDoc,
  IdentityDoc,
  OtpCodeDoc,
  OtpSendDoc,
  RateLimitDoc,
  RefreshTokenDoc,
  UserDoc,
} from './documents';

/**
 * The one MongoDB connection per server instance.
 *
 * ## Why a shared client rather than a client per request
 *
 * The driver's `MongoClient` *is* the connection pool. Constructing one per
 * request would open a fresh pool — and a fresh TLS handshake and SRV lookup —
 * every time, which on Atlas costs hundreds of milliseconds and exhausts the
 * cluster's connection limit under trivial load. One client, shared, is what the
 * driver is designed for and what every read and write here goes through.
 *
 * ## What changed from `server/src/db/mongo.js`, and why it had to
 *
 * The Express version exposed a **synchronous** `getDb()` that *threw* if
 * `connect()` had not already resolved:
 *
 * ```js
 * export function getDb() {
 *   if (!db) throw new Error('MongoDB is not connected yet — call connect() during boot.');
 *   return db;
 * }
 * ```
 *
 * That was correct there. `index.js` awaited `connect()` and `ensureIndexes()`
 * before it called `app.listen()`, so by the time any handler could run the
 * connection existed, and the throw caught a boot-order bug rather than a
 * runtime condition.
 *
 * **There is no boot on Vercel.** A serverless function is invoked cold, runs a
 * request, and may be frozen immediately after. Nothing runs before the first
 * handler, so a synchronous `getDb()` would throw on every cold invocation —
 * the whole API would fail until a warm instance happened to serve you.
 *
 * So the accessor is now `async` and awaits the memoized connect. The memo is
 * the part that makes this safe rather than merely working: the second caller
 * awaits the first one's promise instead of racing it, so a burst of concurrent
 * requests on a cold instance opens **one** pool, not one per request. The
 * original file already anticipated this — its comment notes that "serverless
 * hosts re-enter the module on a warm start and would otherwise open a second
 * pool on every invocation" — and that reasoning is now load-bearing rather
 * than defensive.
 *
 * The cost is that every call site gains an `await`. That is a wide but shallow
 * change, and it is the honest one: the connection genuinely is asynchronous,
 * and the old signature was only able to pretend otherwise because something
 * else had already done the waiting.
 *
 * ## Why the cache hangs off `globalThis`
 *
 * Next.js re-evaluates modules on every edit in development, and each
 * re-evaluation would otherwise construct a new client and leak the previous
 * pool — a few dozen saves is enough to exhaust an Atlas free tier's connection
 * allowance. Stashing the promise on `globalThis`, which survives module
 * replacement, is the standard remedy and costs nothing in production.
 */

/**
 * Point the SRV lookup at resolvers that will answer it.
 *
 * ## Why this is at module scope rather than inside `connect()`
 *
 * `mongodb+srv://` is not an address — it is an instruction to look up a DNS
 * **SRV** record. The driver does that with `dns.resolveSrv`, which talks to a
 * DNS server directly on port 53 instead of going through the OS resolver, and
 * a surprising number of networks answer ordinary A records while refusing SRV:
 * corporate DNS, a VPN capturing port 53, an unusual router. The symptom is
 * `querySrv ECONNREFUSED`, which the driver reports and which therefore reads
 * like a database fault — it is not, and it happens before a byte reaches
 * Atlas.
 *
 * This was first written inside `connect()`, which *looked* equivalent and was
 * not: by then Node has already created and used its resolver channel, and the
 * override does not reliably apply to the resolution already being set up. The
 * observable result was a cold start that failed once with `db: down` and then
 * succeeded on the retry — an intermittent first-request failure, which is the
 * worst kind. At module scope it runs exactly once, before anything resolves
 * anything.
 *
 * Affects `dns.resolve*` only, so ordinary outbound connections keep using the
 * machine's own configuration. Empty on Vercel, whose resolver handles SRV
 * correctly, making this a no-op there.
 */
if (env.dnsServers.length > 0) {
  dns.setServers(env.dnsServers);
  log.info(`DNS overridden for SRV — ${env.dnsServers.join(', ')}`, 'db');
}

interface MongoCache {
  client: MongoClient | null;
  db: Db | null;
  connecting: Promise<Db> | null;
}

const globalForMongo = globalThis as typeof globalThis & {
  __aurixMongo?: MongoCache;
};

const cache: MongoCache = (globalForMongo.__aurixMongo ??= {
  client: null,
  db: null,
  connecting: null,
});

/**
 * Opens the connection, or returns the one already open.
 *
 * Idempotent and safe to call from anywhere, any number of times, concurrently.
 */
export async function connect(): Promise<Db> {
  if (cache.db) return cache.db;
  if (cache.connecting) return cache.connecting;

  // Checked here rather than at module load: on serverless this is the earliest
  // point that corresponds to "boot" on a long-lived server, and a module-level
  // throw would fail `next build` on a machine that legitimately has no
  // production secrets. See the note in config/env.ts.
  assertConfigured();


  cache.connecting = (async () => {
    const client = new MongoClient(env.mongoUri, {
      // Bounded so a burst of traffic cannot exhaust the Atlas tier's
      // connection allowance. Lower than the server's 10, deliberately: a
      // long-lived server had one pool for the whole deployment, whereas
      // serverless may have many instances warm at once, and each one holding
      // 10 connections is how a free or shared tier runs out. Each instance
      // handles few concurrent requests, so a small pool is sufficient.
      maxPoolSize: 5,
      // No `minPoolSize`. Keeping connections warm is pointless when the
      // instance may be frozen between requests, and it makes a cold start
      // slower by opening sockets the request does not need.
      minPoolSize: 0,
      // Fail fast rather than hanging a request for the driver's 30s default. A
      // caller that gets an error in 8 seconds can retry; one still waiting at
      // 30 has already lost the user — and on Vercel would be close to the
      // function timeout.
      serverSelectionTimeoutMS: 8000,
      connectTimeoutMS: 10000,
      retryWrites: true,
      retryReads: true,
    });

    await client.connect();
    const db = client.db(env.dbName);

    cache.client = client;
    cache.db = db;
    log.info(`MongoDB connected — database "${env.dbName}"`, 'db');
    return db;
  })();

  try {
    return await cache.connecting;
  } catch (error) {
    // Clear the memo so a later call can retry instead of re-awaiting a
    // permanently rejected promise. Without this, one failed connection on a
    // cold start would poison the instance for as long as it stays warm.
    cache.connecting = null;
    cache.client = null;
    cache.db = null;

    // Say what happened, here, once.
    //
    // On the old server a failed connection happened during boot, where
    // `index.js` logged it and refused to start — impossible to miss. Here the
    // only caller that reaches a user is `/health`, which deliberately reports
    // `db: down` rather than an error, and `ping()` swallows the cause to do
    // that. Without this line a misconfigured deployment answers 503 with no
    // explanation anywhere, which is exactly the failure that is hardest to
    // diagnose from the outside.
    log.error('MongoDB connection failed', 'db', error);
    throw error;
  }
}

/** The database handle, connecting first if necessary. */
export async function getDb(): Promise<Db> {
  return cache.db ?? connect();
}

/**
 * A typed accessor per collection, so no route spells a collection name.
 *
 * The identity and token collections carry concrete document types, written
 * from the services that own them. The library and catalogue collections are
 * still `Document` — their services land in Phase 6, and a document type
 * guessed ahead of its write path is worse than one that is loose.
 */
async function collection<T extends Document = Document>(
  key: CollectionKey,
): Promise<Collection<T>> {
  const db = await getDb();
  return db.collection<T>(COLLECTIONS[key]);
}

export const collections = {
  users: () => collection<UserDoc>('users'),
  identities: () => collection<IdentityDoc>('identities'),
  refreshTokens: () => collection<RefreshTokenDoc>('refreshTokens'),
  actionTokens: () => collection<ActionTokenDoc>('actionTokens'),
  otpCodes: () => collection<OtpCodeDoc>('otpCodes'),
  otpSends: () => collection<OtpSendDoc>('otpSends'),
  authStates: () => collection<AuthStateDoc>('authStates'),
  authGrants: () => collection<AuthGrantDoc>('authGrants'),
  rateLimits: () => collection<RateLimitDoc>('rateLimits'),
  likedTracks: () => collection('likedTracks'),
  recentlyPlayed: () => collection('recentlyPlayed'),
  userPlaylists: () => collection('userPlaylists'),
  userPlaylistTracks: () => collection('userPlaylistTracks'),
  catalogSongs: () => collection<CatalogSongDoc>('catalogSongs'),
  globalPlaylists: () => collection<GlobalPlaylistDoc>('globalPlaylists'),
  globalPlaylistTracks: () => collection('globalPlaylistTracks'),
  appConfig: () => collection<AppConfigDoc>('appConfig'),
};

/** The GridFS bucket that holds uploaded logos, icons and font files. */
export async function brandAssets(): Promise<GridFSBucket> {
  const db = await getDb();
  return new GridFSBucket(db, { bucketName: GRIDFS_BUCKET });
}

/**
 * Creates every index the API's queries depend on.
 *
 * ## Why this is no longer called at boot
 *
 * The Express server ran this on every start, which was cheap and safe —
 * `createIndexes` is idempotent, so an index that already exists with the same
 * key and options is a no-op.
 *
 * On serverless there is no start, and running it per request would add a round
 * trip to every cold invocation for a result that is almost always "nothing to
 * do". Worse, the drop-and-recreate branch below would then be racing itself
 * across concurrent instances, and the window in which a unique constraint is
 * absent would open on live traffic rather than during a controlled restart.
 *
 * So it moved to `npm run indexes`, run once against a deployment. The
 * uniqueness constraints are the schema — `(uid, trackId)` unique on liked
 * tracks is what makes liking the same song twice a single row — so this is a
 * required deployment step, not an optimisation.
 */
export async function ensureIndexes(): Promise<void> {
  const db = await getDb();
  const results: string[] = [];

  for (const [name, specs] of Object.entries(INDEXES) as [CollectionKey, typeof INDEXES[CollectionKey]][]) {
    if (specs.length === 0) continue;
    const target = db.collection(COLLECTIONS[name]);

    try {
      const created = await target.createIndexes(specs);
      results.push(`${COLLECTIONS[name]}:${created.length}`);
    } catch (error) {
      const code = (error as { code?: number })?.code;
      const message = error instanceof Error ? error.message : String(error);

      // 85 IndexOptionsConflict / 86 IndexKeySpecsConflict: an index of this
      // name already exists with *different* options. That is what a spec
      // change looks like from here, and it is a real one — `users.email`
      // became sparse when phone sign-in arrived, because an account created
      // from a phone number has no email field and a non-sparse unique index
      // permits exactly one document that is missing it.
      //
      // Mongo will not alter an index in place, so the only way forward is
      // drop-and-recreate. The window in which the unique constraint is absent
      // is the length of one createIndex. Said out loud in the log so whoever
      // runs it knows what happened — and it is now a deliberate operator
      // action rather than something that happened during a boot nobody watched.
      if (code === 85 || code === 86) {
        log.warn(
          `Index definitions on ${COLLECTIONS[name]} have changed — rebuilding: ${message}`,
          'db',
        );
        try {
          for (const spec of specs) {
            if (spec.name) await target.dropIndex(spec.name).catch(() => undefined);
          }
          const created = await target.createIndexes(specs);
          results.push(`${COLLECTIONS[name]}:${created.length}*`);
          continue;
        } catch (retryError) {
          log.error(`Could not rebuild indexes on ${COLLECTIONS[name]}`, 'db', retryError);
          continue;
        }
      }

      // Anything else is a deployment concern, not a reason to refuse to serve
      // traffic. Say so loudly and carry on.
      log.warn(`Could not create indexes on ${COLLECTIONS[name]}: ${message}`, 'db');
    }
  }

  log.info(`Indexes ensured — ${results.join(' ')}`, 'db');
}

/**
 * Liveness probe for `/health`. Cheap — one admin command, no collection scan.
 *
 * Unlike the Express version, this *connects* if it is not already connected.
 * There the answer to "is the database up?" on an unconnected process meant a
 * boot failure; here it just means a cold instance, and answering `false`
 * because nothing had opened a socket yet would make the health check report an
 * outage on every cold start.
 */
export async function ping(): Promise<boolean> {
  try {
    const db = await getDb();
    await db.command({ ping: 1 });
    return true;
  } catch {
    return false;
  }
}

/**
 * Closes the connection.
 *
 * **Never call this from a request handler.** On a long-lived server this ran
 * on SIGTERM, to hand connections back rather than let Atlas time them out. A
 * serverless instance is frozen and thawed between requests, and closing the
 * pool at the end of one would force the next to pay a full reconnect —
 * turning a warm invocation into a cold one.
 *
 * It exists for scripts and tests, which genuinely do need the process to exit.
 */
export async function close(): Promise<void> {
  if (!cache.client) return;
  await cache.client.close();
  cache.client = null;
  cache.db = null;
  cache.connecting = null;
  log.info('MongoDB connection closed', 'db');
}
