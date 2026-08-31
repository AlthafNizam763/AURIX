import type { AnyBulkWriteOperation, Collection, Document } from 'mongodb';

import type { MusicProviderId } from '../../config/env';
import { collections } from '../../db/mongo';
import { log } from '../../utils/logger';
import { tokensForSong } from '../../utils/search';
import { mergeDelta, preferRicher, type SongIn } from '../catalog';
import { namedFields, writeTracksInOrder } from '../playlists';
import { recount } from '../shared-playlists';
import { metadataKey, playlistKey, trackKey } from './keys';
import type { FetchedPlaylist, ProviderTrack } from './types';

/**
 * Writing a fetched playlist into AURIX.
 *
 * ```
 * Provider playlist
 *        ↓ normalise            provider shapes → one AURIX shape (types.ts)
 *        ↓ existing playlist?   pl_<provider>_<providerPlaylistId>
 *        ↓ existing songs?      <provider>_<providerTrackId>
 *        ↓ create missing songs merge-only, never overwrite
 *        ↓ create playlist      upsert on the derived id
 *        ↓ link songs           position = index, source order preserved
 *        → the AURIX playlist
 * ```
 *
 * ## Identity, and why nothing here is duplicated on a second import
 *
 * Both ids are *derived*, never generated:
 *
 *  * a playlist is `provider + providerPlaylistId`, through [playlistKey];
 *  * a song is `provider + providerTrackId`, through [trackKey].
 *
 * So importing the same playlist twice writes to the same `_id` twice, and the
 * second import updates rather than inserts. There is no "have I seen this
 * before?" query holding that together — the key *is* the answer, which is what
 * makes it correct under concurrency too. Two devices importing the same
 * playlist at the same moment converge on one document rather than racing to
 * create two.
 *
 * ## Songs are merged, never replaced
 *
 * The shared catalogue is written by every user from whatever their source
 * happened to carry, and a Spotify import knows the album and duration where a
 * YouTube import often knows neither. [mergeDelta] therefore only ever fills
 * fields that are *empty*. Replacing the stored row would make the same song
 * gain and lose its album depending on who imported it last — the catalogue
 * would degrade as it grew rather than improve. This is the one write path
 * where the obvious implementation is silently wrong, which is why it reuses
 * the helpers that already got it right.
 *
 * ## What is not written
 *
 * No audio, no file, no stream URL. What is stored is what §6 lists: title,
 * artist, album, artwork, duration, provider, provider track id, the original
 * playlist id, an external link back, and the track's position. `previewUrl` is
 * Spotify's own published 30-second clip and is the only audio URL that ever
 * appears — it is a link to Spotify's CDN, not a copy of anything.
 */

export interface ImportResult {
  playlistId: string;
  name: string;
  coverUrl: string;
  provider: MusicProviderId;
  providerPlaylistId: string;
  externalUrl: string;
  /** Rows now linked to the playlist. The authoritative count. */
  trackCount: number;
  /** Songs this import added to the shared catalogue. */
  songsCreated: number;
  /** Songs that were already there and were reused. */
  songsReused: number;
  /** False when the playlist already existed and was refreshed. */
  created: boolean;
  /** Entries the provider listed that could not be imported. */
  skipped: { position: number; reason: string }[];
  /** True when the fetch stopped at the safety cap. */
  truncated: boolean;
  /** The provider's own count, when it disagrees with [trackCount]. */
  providerTrackCount: number;
}

/**
 * A document addressed by a string `_id`.
 *
 * The driver's bare `Document` models `_id` as an ObjectId, which is right for
 * a collection that lets Mongo generate ids and wrong for every collection this
 * import writes to — a catalogue song is `spotify_4uLU6hMC` and a playlist is
 * `pl_spotify_22WMPdy…`, both derived rather than generated. Naming that here
 * keeps the bulk-write call sites free of casts.
 */
type KeyedDoc = Document & { _id: string };

/**
 * A provider track, as a catalogue song.
 *
 * The one judgement call is the id. A track the provider identified is keyed on
 * that id; one it did not is keyed on its title and artist, so that the same
 * song arriving from two sources without ids collapses into one row instead of
 * accumulating a new document on every import.
 */
function toSong(provider: MusicProviderId, track: ProviderTrack): { id: string; song: SongIn } {
  const artist = track.artists.join(', ');
  const id = track.providerTrackId
    ? trackKey(provider, track.providerTrackId)
    : metadataKey(track.title, artist);

  return {
    id,
    song: {
      id,
      title: track.title || 'Unknown track',
      artists: track.artists,
      album: track.album,
      duration: track.durationMs,
      artworkUrl: track.artworkUrl,
      source: provider,
      sourceId: track.providerTrackId,
      externalUrl: track.externalUrl,
      explicit: track.explicit,
      searchTokens: tokensForSong({ title: track.title, artist, album: track.album }),
      ...(provider === 'spotify' && track.providerTrackId
        ? { spotifyId: track.providerTrackId }
        : {}),
      ...(provider === 'youtube' && track.providerTrackId
        ? { youtubeVideoId: track.providerTrackId }
        : {}),
      ...(track.previewUrl ? { previewUrl: track.previewUrl } : {}),
    },
  };
}

/**
 * A catalogue song, as a playlist row.
 *
 * The two shapes genuinely differ and the difference is not cosmetic: the
 * catalogue stores `artists` as an **array** and the length as `duration`,
 * while a playlist row stores `artist` as a **string** and the length as
 * `durationMs` (see `S.track` in http/validate.ts). Writing one where the other
 * is expected produces rows that parse but render blank, which is precisely the
 * class of bug this function exists to make impossible to write by accident.
 */
function trackRow(song: SongIn): Document {
  return {
    title: song.title,
    artist: song.artists.join(', '),
    album: song.album,
    durationMs: song.duration,
    artworkUrl: song.artworkUrl,
    explicit: song.explicit,
    source: song.source,
    sourceId: song.sourceId,
    ...(song.spotifyId ? { spotifyId: song.spotifyId } : {}),
    ...(song.youtubeVideoId ? { youtubeVideoId: song.youtubeVideoId } : {}),
    ...(song.previewUrl ? { previewUrl: song.previewUrl } : {}),
  };
}

/**
 * Writes [fetched] into the shared catalogue on behalf of [uid].
 *
 * The playlist lands in `globalPlaylists`, which is shared: a playlist imported
 * by one user is findable and playable by every user. Provenance is recorded in
 * `importedByUserId` and does not narrow who may read it — see the note in
 * `db/collections.ts`.
 */
export async function importPlaylist({
  uid,
  importerName,
  provider,
  fetched,
}: {
  uid: string;
  importerName: string;
  provider: MusicProviderId;
  fetched: FetchedPlaylist;
}): Promise<ImportResult> {
  const { playlist, tracks, skipped, truncated } = fetched;
  const playlistId = playlistKey(provider, playlist.providerPlaylistId);
  const now = new Date();

  // ---- Songs ------------------------------------------------------------
  //
  // Collapsed by id *before* anything reaches the database. A playlist may
  // legitimately list the same track twice, and two upserts on one key inside a
  // single bulkWrite would race each other for the same row.
  const byId = new Map<string, SongIn>();
  const orderedIds: string[] = [];

  for (const track of tracks) {
    const { id, song } = toSong(provider, track);
    orderedIds.push(id);
    const existing = byId.get(id);
    byId.set(id, existing ? preferRicher(existing, song) : song);
  }

  const songsCollection = await collections.catalogSongs();
  const ids = [...byId.keys()];

  const stored =
    ids.length > 0
      ? await songsCollection.find({ _id: { $in: ids } }).toArray()
      : [];
  const storedById = new Map(stored.map((doc) => [doc._id, doc as Document]));

  const operations: AnyBulkWriteOperation<KeyedDoc>[] = [];
  let songsCreated = 0;

  for (const [id, song] of byId) {
    const existing = storedById.get(id);

    if (!existing) {
      songsCreated += 1;
      operations.push({
        updateOne: {
          filter: { _id: id },
          // `$setOnInsert` rather than `$set`, so that a concurrent import that
          // wins the race keeps its row and this one does not overwrite it.
          update: { $setOnInsert: { ...song, _id: id, createdAt: now, updatedAt: now } },
          upsert: true,
        },
      });
      continue;
    }

    // Only what this submission genuinely adds. Never a replacement — see the
    // note at the top of this file.
    const delta = mergeDelta(song, existing);
    if (Object.keys(delta).length > 0) {
      operations.push({
        updateOne: {
          filter: { _id: id },
          update: { $set: { ...delta, updatedAt: now } },
        },
      });
    }
  }

  if (operations.length > 0) {
    // Unordered: one failing row must not abandon the rest of the playlist, and
    // the operations are independent of each other by construction.
    //
    // The cast is because `catalogSongs` is a typed collection whose `_id` is a
    // string, and the driver's bulk-write types cannot express "a partial
    // update of this document" without every operation restating the full
    // shape. `playlists.ts` takes the same shortcut, for the same reason.
    await (songsCollection as unknown as Collection<KeyedDoc>).bulkWrite(operations, {
      ordered: false,
    });
  }

  // ---- The playlist -----------------------------------------------------

  const playlists = await collections.globalPlaylists();
  const existingPlaylist = await playlists.findOne(
    { _id: playlistId },
    { projection: { importedByUserId: 1 } },
  );
  const created = !existingPlaylist;

  // Only the original importer may change what every user sees. A later
  // importer contributes tracks and provenance, and does not get to rename the
  // playlist out from under the first — otherwise the title on a shared
  // document would be decided by whoever synced most recently.
  const isImporter = created || existingPlaylist?.importedByUserId === uid;

  await playlists.updateOne(
    { _id: playlistId },
    {
      $set: {
        updatedAt: now,
        syncedAt: now,
        ...(isImporter
          ? {
              ...namedFields(playlist.name),
              description: playlist.description,
              coverUrl: playlist.coverUrl,
              sourceUrl: playlist.externalUrl,
            }
          : {}),
      },
      $setOnInsert: {
        source: provider,
        sourceId: playlist.providerPlaylistId,
        trackCount: 0,
        importedByUserId: uid,
        importedBy: importerName,
        importedAt: now,
        createdAt: now,
        ...(isImporter
          ? {}
          : {
              ...namedFields(playlist.name),
              description: playlist.description,
              coverUrl: playlist.coverUrl,
              sourceUrl: playlist.externalUrl,
            }),
      },
    },
    { upsert: true },
  );

  // ---- Order ------------------------------------------------------------
  //
  // Positions are assigned from the source's order, from the start. A re-import
  // of a playlist the user reordered at the provider therefore ends up matching
  // the provider again, rather than appending the same songs a second time.
  //
  // Routed through the same `writeTracksInOrder` every other write into
  // `globalPlaylistTracks` uses. That matters for a reason easy to miss: a row
  // in that collection **embeds the track**, it is not a foreign key. The read
  // at `GET /shared-playlists/{id}/tracks` maps rows straight out with
  // `trackOut`, so a row carrying only `trackId` would render as a song with no
  // title. Writing bare references here would have produced a playlist of blank
  // rows that looked like a database problem.
  const links = await collections.globalPlaylistTracks();

  const seen = new Set<string>();
  const entries: { trackId: string; track: Document }[] = [];

  for (const trackId of orderedIds) {
    // A playlist may legitimately list the same track twice; the collection's
    // unique index on (playlistId, trackId) makes it one row, and the first
    // occurrence is the one whose position is kept.
    if (seen.has(trackId)) continue;
    seen.add(trackId);

    const song = byId.get(trackId);
    if (!song) continue;
    entries.push({ trackId, track: trackRow(song) });
  }

  await writeTracksInOrder(links, { playlistId }, entries as never);

  // Rows that were in the playlist before and are not in the source any more.
  // Without this, a re-import after the user deleted a song at the provider
  // would leave it in AURIX for ever — the two would drift apart in the one
  // direction a re-sync exists to fix.
  const removed = await links.deleteMany({
    playlistId,
    ...(seen.size > 0 ? { trackId: { $nin: [...seen] } } : {}),
  });
  if (removed.deletedCount > 0) {
    log.info(
      `Import of ${playlistId} dropped ${removed.deletedCount} track(s) no longer in the source`,
      'music',
    );
  }

  // The authoritative count, from the rows that exist — not the provider's own
  // number, which counts entries this import legitimately skipped.
  await recount(playlistId);
  const trackCount = await links.countDocuments({ playlistId });

  log.info(
    `Imported ${provider} playlist ${playlist.providerPlaylistId} as ${playlistId} — ` +
      `${trackCount} track(s), ${songsCreated} new song(s), ${skipped.length} skipped`,
    'music',
  );

  return {
    playlistId,
    name: playlist.name,
    coverUrl: playlist.coverUrl,
    provider,
    providerPlaylistId: playlist.providerPlaylistId,
    externalUrl: playlist.externalUrl,
    trackCount,
    songsCreated,
    songsReused: byId.size - songsCreated,
    created,
    skipped: skipped.map((entry) => ({ position: entry.position, reason: entry.reason })),
    truncated,
    providerTrackCount: playlist.totalTracks,
  };
}
