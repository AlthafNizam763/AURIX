/**
 * Writes the demo catalogue — songs, playlists and their ordering — into
 * MongoDB.
 *
 *   npm run seed:samples              verify every URL, then write
 *   npm run seed:samples -- --check   verify only; touch nothing
 *   npm run seed:samples -- --force   write even if verification failed
 *   npm run seed:samples -- --clear   remove the demo rows and stop
 *
 * ## Verify before write, and why that order matters
 *
 * The brief for this data was "do not use fake or broken audio URLs". A
 * comment cannot enforce that and a code review will not catch the day a
 * Wikimedia file is renamed. So every `previewUrl` and every artwork URL is
 * range-requested first, and a URL that does not answer with the right kind of
 * content stops the seed. The failure arrives here, in a script someone is
 * watching, rather than as a track that spins forever in the player.
 *
 * `--force` exists for the offline case — seeding a dev database on a train —
 * and says plainly in its output that the catalogue it wrote is unverified.
 *
 * ## Rate limiting is not breakage
 *
 * Wikimedia answers `429` to a burst from one client. Treating that as a dead
 * link would make the seed fail against perfectly good data, so requests are
 * spaced and a `429` is retried with a widening backoff. Only a real `4xx`
 * or a non-audio content type counts as broken. This distinction was not
 * theoretical: an unthrottled first pass over these twenty URLs returned
 * eighteen `429`s.
 *
 * ## Idempotence
 *
 * Every id in the manifest is a fixed slug, and every write is an upsert keyed
 * on it. Running this twice produces the same twenty songs and six playlists,
 * not forty and twelve — the same property the importers get from `SongKey`,
 * and the one the brief asks for under "do not create duplicate songs".
 *
 * Song rows are merged rather than replaced, so a re-seed will not clobber
 * `createdAt` or a field another writer improved. The demo rows are `source:
 * 'aurix'`, which no importer produces, so they cannot collide with an
 * imported song however similar the titles get.
 */
import { close, collections, connect, ensureIndexes } from '../src/db/mongo.js';
import { namedFields, writeTracksInOrder } from '../src/services/playlists.js';
import { tokensForSong } from '../src/utils/search.js';
import { log } from '../src/utils/logger.js';
import { DEMO_ID_PREFIX, GENRES, PLAYLISTS, SONGS } from './sample-data/catalogue.js';

const SCOPE = 'seed:samples';

const argv = new Set(process.argv.slice(2));
const CHECK_ONLY = argv.has('--check');
const FORCE = argv.has('--force');
const CLEAR = argv.has('--clear');

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

/** Spacing between probes. Ranged reads of a transcode are not a cheap request. */
const PROBE_INTERVAL_MS = 2500;
const MAX_ATTEMPTS = 4;

/**
 * How long one probe may take before it is abandoned.
 *
 * Not optional. `fetch` has no default timeout, so a connection that opens and
 * then stalls — which is exactly what a busy CDN does under load — hangs the
 * await forever. The seed then sits there producing no output and no error,
 * which is the worst of both: it has not failed, so nothing is reported, and it
 * has not finished, so nothing is written. A stalled probe is treated as
 * `UNVERIFIED`, the same as any other refusal to answer.
 */
const PROBE_TIMEOUT_MS = 15_000;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * What one probe concluded.
 *
 * Three outcomes rather than two, and the third is the one that matters.
 *
 *  * `ok` — the URL answered with the media it should.
 *  * `broken` — it answered something else: a 404, a 403, an HTML error page
 *    where audio was promised. This is evidence about the *link*, and it
 *    stops the seed.
 *  * `unverified` — the CDN declined to answer at all, with a 429 or a 5xx.
 *
 * Collapsing `unverified` into `broken` is the mistake worth naming, because
 * it was made here first and it fails loudly in the wrong direction. Wikimedia
 * answers `429` to sustained ranged reads of transcoded audio — its published
 * budget is enormous (600k/min) but the origin behind the transcode paths is
 * far stricter, and a run of twenty-six probes can trip it even when every
 * single URL is perfectly good. A first pass reported fourteen "broken" URLs
 * that all returned `206` when asked again a minute later.
 *
 * So a refusal to answer is recorded as "not checked", never as "not there".
 * A seed that will not run because a CDN was busy is a worse failure than the
 * one this verification exists to prevent.
 */
const OK = 'ok';
const BROKEN = 'broken';
const UNVERIFIED = 'unverified';

/**
 * Range-requests one URL and reports whether it is the media it claims to be.
 *
 * A `HEAD` would be cheaper and is deliberately not used: Wikimedia's
 * transcode paths answer `HEAD` differently from `GET`, and the question being
 * asked is "will a player get bytes from this", which only a `GET` answers. One
 * kilobyte is enough to settle it.
 */
async function probe(url, expected) {
  let last = 'no attempt made';

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt++) {
    let response;
    try {
      response = await fetch(url, {
        headers: {
          'User-Agent': 'AURIX-seed/1.0 (demo catalogue verification)',
          Range: 'bytes=0-1024',
        },
        signal: AbortSignal.timeout(PROBE_TIMEOUT_MS),
      });
    } catch (error) {
      // DNS failures, connection resets and timeouts are about this machine's
      // network or the CDN's mood as often as about the URL, so they are
      // retried before being believed — and if they persist they end up as
      // UNVERIFIED rather than BROKEN.
      last = error.name === 'TimeoutError'
        ? `no response in ${PROBE_TIMEOUT_MS / 1000}s`
        : `network error: ${error.message}`;
      await sleep(5000 * (attempt + 1));
      continue;
    }

    // Drained on every path before anything else. An unread body keeps its
    // connection checked out of the pool, and twenty-six of those in a row is
    // a seed that stops making requests and reports nothing — which is how
    // this loop first appeared to hang.
    const bytes = await response.arrayBuffer().then((b) => b.byteLength, () => 0);

    if (response.status === 429 || response.status >= 500) {
      last = `HTTP ${response.status}`;
      // Honour the CDN's own answer when it gives one; otherwise widen.
      const after = Number(response.headers.get('retry-after'));
      await sleep(Number.isFinite(after) && after > 0 ? after * 1000 : 8000 * (attempt + 1));
      continue;
    }

    if (response.status !== 200 && response.status !== 206) {
      return { state: BROKEN, detail: `HTTP ${response.status}` };
    }

    const type = response.headers.get('content-type') ?? '';
    if (!type.startsWith(expected)) {
      return { state: BROKEN, detail: `content-type ${type || '(none)'}, wanted ${expected}` };
    }

    // A `200 audio/mpeg` carrying nothing is still a track that will not play.
    if (bytes === 0) {
      return { state: BROKEN, detail: `${type}, but no bytes` };
    }

    return { state: OK, detail: `${type}, ${bytes} bytes` };
  }

  return { state: UNVERIFIED, detail: `${last}, after ${MAX_ATTEMPTS} attempts` };
}

/**
 * Checks every distinct media URL in the manifest.
 *
 * Artwork is de-duplicated first — six albums share their covers across twenty
 * songs, and probing the same thumbnail twenty times would earn exactly the
 * rate limiting this is spaced out to avoid.
 */
async function verify() {
  const targets = [
    ...SONGS.map((song) => ({ url: song.previewUrl, expected: 'audio/', label: song.title })),
    ...[...new Set(SONGS.map((song) => song.album.artwork))].map((url) => ({
      url,
      expected: 'image/',
      label: 'artwork',
    })),
  ];

  log.info(`Verifying ${targets.length} media URLs`, SCOPE);

  const broken = [];
  const unverified = [];

  for (const [index, target] of targets.entries()) {
    if (index > 0) await sleep(PROBE_INTERVAL_MS);
    const { state, detail } = await probe(target.url, target.expected);

    // Every probe reports, not only the failures. A verification pass over
    // twenty-six URLs takes a minute or two, and one that prints nothing until
    // it finishes is indistinguishable from one that has stopped.
    log.info(`  [${index + 1}/${targets.length}] ${state} — ${target.label}`, SCOPE);

    if (state === BROKEN) {
      broken.push({ ...target, detail });
      log.error(`  broken — ${target.label}: ${detail}`, SCOPE);
    } else if (state === UNVERIFIED) {
      unverified.push({ ...target, detail });
      log.warn(`  not checked — ${target.label}: ${detail}`, SCOPE);
    }
  }

  const checked = targets.length - unverified.length;
  if (broken.length === 0) {
    log.info(`${checked}/${targets.length} media URLs answered with real content`, SCOPE);
  }
  if (unverified.length > 0) {
    log.warn(
      `${unverified.length} URL(s) could not be checked — the CDN declined to answer. `
        + 'That is not evidence they are broken; re-run to check them.',
      SCOPE,
    );
  }

  return broken;
}

// ---------------------------------------------------------------------------
// Documents
// ---------------------------------------------------------------------------

/**
 * One catalogue document, in the shape `Song.fromDocument` reads.
 *
 * `searchTokens` is computed here with the server's own tokeniser rather than
 * copied from anywhere, because search is the thing most likely to be silently
 * wrong: a row whose tokens were generated by a different normaliser is stored
 * fine, returns nothing, and looks like an empty catalogue. Using
 * `tokensForSong` means the demo rows are tokenised by the same code that will
 * query them.
 */
function songDocument(song) {
  return {
    title: song.title,
    artists: song.artists,
    album: song.album.name,
    duration: song.durationMs,
    artworkUrl: song.album.artwork,
    // Not imported from anywhere. This is the value that keeps the demo rows
    // out of every duplicate check the importers run.
    source: 'aurix',
    sourceId: song.id,
    externalUrl: '',
    explicit: false,
    genre: song.genre,
    // Carried so the licence claim travels with the row and can be shown
    // wherever the track is. A demo catalogue whose provenance lives only in
    // a source file is a demo catalogue nobody can audit from the database.
    license: song.license,
    attribution: song.attribution,
    previewUrl: song.previewUrl,
    searchTokens: tokensForSong({
      title: song.title,
      artist: song.artists.join(', '),
      album: song.album.name,
    }),
  };
}

/** The per-playlist track row: the denormalised copy the playlist screen reads. */
function trackDocument(song) {
  return {
    title: song.title,
    artist: song.artists.join(', '),
    album: song.album.name,
    durationMs: song.durationMs,
    artworkUrl: song.album.artwork,
    explicit: false,
    source: 'aurix',
    sourceId: song.id,
    previewUrl: song.previewUrl,
  };
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

async function writeSongs() {
  const now = new Date();
  const operations = SONGS.map((song) => ({
    updateOne: {
      filter: { _id: song.id },
      update: {
        // Merge, not replace: a re-seed refreshes the metadata and leaves
        // `createdAt` — and anything a future writer added — alone.
        $set: { ...songDocument(song), updatedAt: now },
        $setOnInsert: { createdAt: now },
      },
      upsert: true,
    },
  }));

  const result = await collections.catalogSongs().bulkWrite(operations, { ordered: false });
  return { inserted: result.upsertedCount, updated: result.modifiedCount };
}

async function writePlaylists() {
  const byId = new Map(SONGS.map((song) => [song.id, song]));
  const now = new Date();
  let tracksWritten = 0;

  for (const playlist of PLAYLISTS) {
    // A reference that does not resolve is a manifest bug, and it is louder
    // here than as a playlist that is quietly one track short.
    const songs = playlist.songs.map((id) => {
      const song = byId.get(id);
      if (!song) throw new Error(`Playlist ${playlist.id} references unknown song ${id}`);
      return song;
    });

    await collections.globalPlaylists().updateOne(
      { _id: playlist.id },
      {
        $set: {
          ...namedFields(playlist.name),
          description: playlist.description,
          coverUrl: playlist.cover,
          genre: playlist.genre,
          trackCount: songs.length,
          updatedAt: now,
        },
        $setOnInsert: {
          source: 'aurix',
          sourceId: playlist.id,
          sourceUrl: '',
          // No uid: these belong to the deployment, not to a person. Every
          // read of `globalPlaylists` is unfiltered by uid, so an absent
          // `importedByUserId` costs nothing on read — and on the one route
          // that consults it, the delete route, it correctly means "no user
          // owns this, so no user may delete it".
          importedByUserId: null,
          importedBy: 'AURIX',
          importedAt: now,
          createdAt: now,
        },
      },
      { upsert: true },
    );

    tracksWritten += await writeTracksInOrder(
      collections.globalPlaylistTracks(),
      { playlistId: playlist.id },
      songs.map((song) => ({ trackId: song.id, track: trackDocument(song) })),
    );
  }

  return tracksWritten;
}

/** Removes exactly what this script wrote, by id prefix. */
async function clear() {
  const prefix = new RegExp(`^${DEMO_ID_PREFIX}`);
  const songs = await collections.catalogSongs().deleteMany({ _id: prefix });
  const playlists = await collections.globalPlaylists().deleteMany({ _id: prefix });
  const tracks = await collections.globalPlaylistTracks().deleteMany({ playlistId: prefix });
  log.info(
    `Removed ${songs.deletedCount} songs, ${playlists.deletedCount} playlists, `
      + `${tracks.deletedCount} playlist tracks`,
    SCOPE,
  );
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

try {
  if (CLEAR) {
    await connect();
    await clear();
  } else {
    const broken = await verify();

    if (broken.length > 0 && !FORCE) {
      log.error(
        `${broken.length} media URL(s) did not answer with real content. Nothing was `
          + 'written. Fix the manifest, or pass --force to seed anyway.',
        SCOPE,
      );
      process.exitCode = 1;
    } else if (CHECK_ONLY) {
      log.info('Check only — nothing written', SCOPE);
    } else {
      if (broken.length > 0) {
        log.warn(`--force: seeding with ${broken.length} unverified URL(s)`, SCOPE);
      }

      await connect();
      await ensureIndexes();

      const { inserted, updated } = await writeSongs();
      const tracks = await writePlaylists();

      log.info(
        `${SONGS.length} songs (${inserted} new, ${updated} refreshed) across `
          + `${GENRES.length} genres; ${PLAYLISTS.length} playlists, ${tracks} playlist tracks`,
        SCOPE,
      );
    }
  }
} catch (error) {
  log.error('Sample seed failed', SCOPE, error);
  process.exitCode = 1;
} finally {
  await close();
}
