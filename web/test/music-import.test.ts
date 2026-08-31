import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { env } from '@/server/config/env';
import { close, collections } from '@/server/db/mongo';
import { importPlaylist } from '@/server/services/music/import';
import { playlistKey, trackKey } from '@/server/services/music/keys';
import type { FetchedPlaylist, ProviderTrack } from '@/server/services/music/types';

/**
 * The import, against the real database.
 *
 * ## Why this one is not mocked
 *
 * Every claim §7 makes is a claim about *MongoDB* — that a second import lands
 * on one document, that a song already in the catalogue is reused, that a
 * playlist's order survives, that a unique index makes a repeated track one
 * row. A mocked collection would assert that the code calls the driver the way
 * the test expects, which is a restatement of the implementation and would pass
 * just as happily with the upserts pointed at the wrong keys.
 *
 * So this talks to the cluster in `.env.local`, and skips itself when there is
 * none — the same convention the other database-backed suites here follow.
 *
 * Everything it writes is namespaced under a synthetic provider playlist id and
 * removed afterwards, so it is safe against a live database.
 */

const RUN = Boolean(env.mongoUri && env.jwtSecret);
const suite = RUN ? describe : describe.skip;

// Namespaced so nothing here can collide with real imported data.
const PROVIDER_PLAYLIST_ID = 'vitest22WMPdyCLdKfeRr';
const PLAYLIST_ID = playlistKey('spotify', PROVIDER_PLAYLIST_ID);
const UID = 'vitest-import-user';

const track = (id: string, over: Partial<ProviderTrack> = {}): ProviderTrack => ({
  providerTrackId: id,
  title: `Song ${id}`,
  artists: ['An Artist'],
  album: 'An Album',
  durationMs: 200_000,
  artworkUrl: `https://img/${id}.jpg`,
  explicit: false,
  externalUrl: `https://open.spotify.com/track/${id}`,
  ...over,
});

const fetched = (tracks: ProviderTrack[], over: Partial<FetchedPlaylist> = {}): FetchedPlaylist => ({
  playlist: {
    providerPlaylistId: PROVIDER_PLAYLIST_ID,
    name: 'Vitest Night Drive',
    description: 'written by a test',
    coverUrl: 'https://img/cover.jpg',
    ownerName: 'Tester',
    totalTracks: tracks.length,
    externalUrl: `https://open.spotify.com/playlist/${PROVIDER_PLAYLIST_ID}`,
  },
  tracks,
  skipped: [],
  truncated: false,
  ...over,
});

const run = (tracks: ProviderTrack[], over: Partial<FetchedPlaylist> = {}, uid = UID) =>
  importPlaylist({
    uid,
    importerName: 'Vitest',
    provider: 'spotify',
    fetched: fetched(tracks, over),
  });

/** The playlist's rows, in stored order. */
async function storedOrder(): Promise<string[]> {
  const links = await collections.globalPlaylistTracks();
  const rows = await links.find({ playlistId: PLAYLIST_ID }).sort({ position: 1 }).toArray();
  return rows.map((row) => String(row.trackId));
}

async function cleanUp(): Promise<void> {
  const playlists = await collections.globalPlaylists();
  const links = await collections.globalPlaylistTracks();
  const songs = await collections.catalogSongs();

  await playlists.deleteMany({ _id: PLAYLIST_ID });
  await links.deleteMany({ playlistId: PLAYLIST_ID });
  await songs.deleteMany({ _id: { $regex: '^spotify_vitest' } });
}

suite('importing a playlist into MongoDB', () => {
  beforeAll(cleanUp);
  afterAll(async () => {
    await cleanUp();
    await close();
  });

  it('creates the playlist, its songs and their order', async () => {
    const result = await run([
      track('vitestT1'),
      track('vitestT2'),
      track('vitestT3'),
    ]);

    expect(result.created).toBe(true);
    expect(result.playlistId).toBe(PLAYLIST_ID);
    expect(result.trackCount).toBe(3);
    expect(result.songsCreated).toBe(3);

    // Order is load-bearing — it is what Next and Previous follow.
    expect(await storedOrder()).toEqual([
      trackKey('spotify', 'vitestT1'),
      trackKey('spotify', 'vitestT2'),
      trackKey('spotify', 'vitestT3'),
    ]);
  });

  it('stores the playlist row with its external identity', async () => {
    const playlists = await collections.globalPlaylists();
    const doc = await playlists.findOne({ _id: PLAYLIST_ID });

    expect(doc).toBeTruthy();
    expect(doc!.source).toBe('spotify');
    expect(doc!.sourceId).toBe(PROVIDER_PLAYLIST_ID);
    expect(doc!.name).toBe('Vitest Night Drive');
    expect(doc!.trackCount).toBe(3);
    expect(doc!.importedByUserId).toBe(UID);
  });

  it('writes rows the tracks endpoint can actually render', async () => {
    // A row in `globalPlaylistTracks` embeds the track; it is not a foreign
    // key. Writing bare references would produce a playlist of blank rows that
    // looked like a database fault — see `trackRow` in import.ts.
    const links = await collections.globalPlaylistTracks();
    const row = await links.findOne({
      playlistId: PLAYLIST_ID,
      trackId: trackKey('spotify', 'vitestT1'),
    });

    expect(row).toBeTruthy();
    expect(row!.title).toBe('Song vitestT1');
    // `artist` is a string here and `artists` is an array in the catalogue.
    expect(row!.artist).toBe('An Artist');
    expect(row!.durationMs).toBe(200_000);
    expect(row!.spotifyId).toBe('vitestT1');
  });

  it('stores the catalogue song under provider + provider track id', async () => {
    const songs = await collections.catalogSongs();
    const song = await songs.findOne({ _id: trackKey('spotify', 'vitestT1') });

    expect(song).toBeTruthy();
    expect(song!.artists).toEqual(['An Artist']);
    expect(song!.duration).toBe(200_000);
    expect(song!.sourceId).toBe('vitestT1');
    expect(song!.searchTokens.length).toBeGreaterThan(0);
  });

  it('does not duplicate anything on a second import of the same playlist', async () => {
    // The requirement in one test. `provider + providerPlaylistId` is the
    // playlist's identity and `provider + providerTrackId` is a song's, so the
    // second import updates rather than inserting.
    const result = await run([
      track('vitestT1'),
      track('vitestT2'),
      track('vitestT3'),
    ]);

    expect(result.created).toBe(false);
    expect(result.songsCreated).toBe(0);
    expect(result.songsReused).toBe(3);
    expect(result.trackCount).toBe(3);

    const playlists = await collections.globalPlaylists();
    expect(await playlists.countDocuments({ sourceId: PROVIDER_PLAYLIST_ID })).toBe(1);

    const links = await collections.globalPlaylistTracks();
    expect(await links.countDocuments({ playlistId: PLAYLIST_ID })).toBe(3);
  });

  it('a re-import reconciles: adds, removes and reorders to match the source', async () => {
    // T2 is gone at the source, T4 is new, and the rest has been reordered.
    const result = await run([track('vitestT3'), track('vitestT4'), track('vitestT1')]);

    expect(result.trackCount).toBe(3);
    expect(result.songsCreated).toBe(1);

    expect(await storedOrder()).toEqual([
      trackKey('spotify', 'vitestT3'),
      trackKey('spotify', 'vitestT4'),
      trackKey('spotify', 'vitestT1'),
    ]);

    // Removed from the playlist…
    const links = await collections.globalPlaylistTracks();
    expect(
      await links.countDocuments({
        playlistId: PLAYLIST_ID,
        trackId: trackKey('spotify', 'vitestT2'),
      }),
    ).toBe(0);

    // …but not from the shared catalogue, where another playlist may use it.
    const songs = await collections.catalogSongs();
    expect(await songs.countDocuments({ _id: trackKey('spotify', 'vitestT2') })).toBe(1);
  });

  it('improves a catalogue song without ever overwriting it', async () => {
    // A second source knows the album this one did not, and does not know the
    // artwork this one did. The stored row must end up with both.
    const songs = await collections.catalogSongs();
    await songs.updateOne(
      { _id: trackKey('spotify', 'vitestT1') },
      { $set: { album: '', artworkUrl: 'https://img/original.jpg' } },
    );

    await run([track('vitestT1', { album: 'A Better Album', artworkUrl: '' })]);

    const song = await songs.findOne({ _id: trackKey('spotify', 'vitestT1') });
    expect(song!.album).toBe('A Better Album');
    // Not blanked by the incoming empty value.
    expect(song!.artworkUrl).toBe('https://img/original.jpg');
  });

  it('collapses a track listed twice into one row', async () => {
    // The unique index on (playlistId, trackId) requires it, and two upserts on
    // one key inside a single bulkWrite would otherwise race each other.
    const result = await run([
      track('vitestT1'),
      track('vitestT2'),
      track('vitestT1'),
    ]);

    expect(result.trackCount).toBe(2);
    expect(await storedOrder()).toEqual([
      trackKey('spotify', 'vitestT1'),
      trackKey('spotify', 'vitestT2'),
    ]);
  });

  it('handles an empty playlist without failing', async () => {
    const result = await run([]);

    expect(result.trackCount).toBe(0);
    expect(await storedOrder()).toEqual([]);

    // The playlist itself is still there — an empty playlist is a playlist.
    const playlists = await collections.globalPlaylists();
    expect(await playlists.countDocuments({ _id: PLAYLIST_ID })).toBe(1);
  });

  it('handles a large playlist in one pass', async () => {
    const many = Array.from({ length: 500 }, (_, i) =>
      track(`vitestBig${String(i).padStart(3, '0')}`),
    );

    const result = await run(many);

    expect(result.trackCount).toBe(500);
    const order = await storedOrder();
    expect(order).toHaveLength(500);
    expect(order[0]).toBe(trackKey('spotify', 'vitestBig000'));
    expect(order[499]).toBe(trackKey('spotify', 'vitestBig499'));
  }, 60_000);

  it('reports what it could not import rather than swallowing it', async () => {
    const result = await run([track('vitestT1')], {
      skipped: [
        { position: 2, reason: 'deleted' },
        { position: 5, reason: 'local_file' },
      ],
      truncated: true,
    });

    expect(result.skipped).toEqual([
      { position: 2, reason: 'deleted' },
      { position: 5, reason: 'local_file' },
    ]);
    expect(result.truncated).toBe(true);
    // The provider's own count and the rows actually written are allowed to
    // disagree; `trackCount` is the authoritative one.
    expect(result.trackCount).toBe(1);
  });

  it('lets a second user contribute without letting them rename it', async () => {
    // The shared catalogue's rule: a later importer adds tracks and provenance,
    // and does not get to change the title every user sees.
    await importPlaylist({
      uid: 'vitest-other-user',
      importerName: 'Someone Else',
      provider: 'spotify',
      fetched: {
        ...fetched([track('vitestT1')]),
        playlist: { ...fetched([]).playlist, name: 'Renamed By A Stranger' },
      },
    });

    const playlists = await collections.globalPlaylists();
    const doc = await playlists.findOne({ _id: PLAYLIST_ID });

    expect(doc!.name).toBe('Vitest Night Drive');
    expect(doc!.importedByUserId).toBe(UID);
  });
});
