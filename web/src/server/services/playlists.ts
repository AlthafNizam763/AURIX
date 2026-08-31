import type { AnyBulkWriteOperation, Collection, Document, Filter } from 'mongodb';

import { iso } from '../utils/json';
import { normaliseAlbum, tokensForPlaylist } from '../utils/search';

/**
 * The ordering and track-write rules shared by the two playlist collections.
 *
 * A user's own playlists and the shared imported catalogue are separate
 * collections with different access rules, but the *mechanics* of holding an
 * ordered track list are identical. They live here so the two route files
 * cannot drift — which they did in the Firestore original, where
 * `writeTracksInOrder` existed twice with subtly different de-duplication.
 */

/**
 * The gap left between adjacent tracks.
 *
 * Large enough that fifty inserts between the same pair still find a midpoint.
 * This is the whole reason `position` is a double rather than an integer: with
 * integers, dropping a track between two others renumbers everything after it,
 * so one drag is N writes. With a gap, the new position is the midpoint of its
 * neighbours and one row changes.
 */
export const POSITION_GAP = 1024;

/** Below this, two positions are too close to reliably find a midpoint. */
export const MINIMUM_GAP = 0.0001;

/** A track as the client submits it: an id plus the row to store under it. */
export interface TrackEntry {
  trackId: string;
  track: Record<string, unknown>;
}

/** The scope that identifies one playlist's rows — `{uid, playlistId}` or `{playlistId}`. */
export type TrackScope = Record<string, string>;

/**
 * The position for a track landing between two neighbours, or `null` when the
 * gap has collapsed and the list needs renumbering.
 *
 * The Dart original is kept as a pure static so `playlist_position_test.dart`
 * still exercises the same arithmetic on the client side.
 */
export function positionBetween(before: number | null, after: number | null): number | null {
  if (before == null && after == null) return POSITION_GAP;
  if (before == null) return after! - POSITION_GAP;
  if (after == null) return before + POSITION_GAP;
  if (Math.abs(after - before) < MINIMUM_GAP) return null;
  return before + (after - before) / 2;
}

export interface PlaylistView {
  id: string;
  name: string;
  description: string;
  coverUrl: string;
  trackCount: number;
  source: string;
  sourceId: string | null;
  sourceUrl: string | null;
  createdAt: string | null;
  updatedAt: string | null;
  syncedAt: string | null;
  importedByUserId: string | null;
  importedBy: string | null;
  importedAt: string | null;
}

/** The shape a playlist document leaves the API in. Mirrors `Playlist.fromDocument`. */
export function playlistOut(doc: Document | null | undefined): PlaylistView | null {
  if (!doc) return null;
  return {
    id: doc.playlistId ?? doc._id,
    name: doc.name ?? '',
    description: doc.description ?? '',
    coverUrl: doc.coverUrl ?? '',
    trackCount: doc.trackCount ?? 0,
    source: doc.source ?? 'aurix',
    sourceId: doc.sourceId ?? null,
    sourceUrl: doc.sourceUrl ?? null,
    createdAt: iso(doc.createdAt),
    updatedAt: iso(doc.updatedAt),
    syncedAt: iso(doc.syncedAt),
    // Provenance. Present only on shared playlists, and never used to narrow a
    // read — see the note in `db/collections.ts`.
    importedByUserId: doc.importedByUserId ?? null,
    importedBy: doc.importedBy ?? null,
    importedAt: iso(doc.importedAt),
  };
}

/**
 * The shape a playlist track row leaves the API in.
 *
 * Strips the storage keys a client should not see and stamps `id` from
 * `trackId`, which is what the Dart models read.
 */
export function trackOut(doc: Document): Document {
  const { _id, uid, playlistId, trackId, position, ...rest } = doc;
  void _id;
  void uid;
  void playlistId;
  void position;
  return { id: trackId, ...rest, createdAt: iso(rest.createdAt) };
}

/**
 * The fields a create or rename writes, including the search index.
 *
 * `searchTokens` is recomputed with the name and **never separately**. A rename
 * that left the tokens behind would leave the playlist findable only by its old
 * title — the kind of bug nobody notices until a user reports it.
 */
export function namedFields(name: unknown): {
  name: string;
  searchTitle: string;
  searchTokens: string[];
} {
  const trimmed = String(name ?? '').trim();
  return {
    name: trimmed,
    searchTitle: normaliseAlbum(trimmed),
    searchTokens: tokensForPlaylist(trimmed),
  };
}

/**
 * Writes an ordered track list, assigning positions from the list index.
 *
 * Distinct from an append: this assigns positions from the *start*, so the
 * playlist ends up in the source's order — what a re-sync wants when the source
 * has reordered, and what a first import wants because there is nothing to
 * append to.
 *
 * Rows are merged rather than replaced, so a track already present keeps its
 * `createdAt` and gains whatever metadata improved. Duplicates within one source
 * playlist are collapsed first: two upserts on one key inside a single
 * `bulkWrite` would otherwise race each other for the same row.
 */
export async function writeTracksInOrder(
  collection: Collection<Document>,
  scope: TrackScope,
  tracks: TrackEntry[],
): Promise<number> {
  if (tracks.length === 0) return 0;

  const seen = new Set<string>();
  const ordered: TrackEntry[] = [];
  for (const entry of tracks) {
    if (!seen.has(entry.trackId)) {
      seen.add(entry.trackId);
      ordered.push(entry);
    }
  }

  const now = new Date();
  const operations: AnyBulkWriteOperation<Document>[] = ordered.map((entry, index) => ({
    updateOne: {
      filter: { ...scope, trackId: entry.trackId } as Filter<Document>,
      update: {
        $set: {
          ...entry.track,
          ...scope,
          trackId: entry.trackId,
          // Position from the index, so playlist order is the source's order.
          // The gap leaves room to drag a track between two others afterwards
          // without a renumber.
          position: (index + 1) * POSITION_GAP,
        },
        $setOnInsert: { createdAt: now },
      },
      upsert: true,
    },
  }));

  // Unordered: the operations touch distinct keys, so letting the driver run
  // them concurrently is safe and materially faster on a long import.
  await collection.bulkWrite(operations, { ordered: false });
  return ordered.length;
}

/** Appends tracks after whatever is already in the list. */
export async function appendTracks(
  collection: Collection<Document>,
  scope: TrackScope,
  tracks: TrackEntry[],
): Promise<number> {
  if (tracks.length === 0) return 0;

  const last = await collection
    .find(scope as Filter<Document>, { projection: { position: 1 } })
    .sort({ position: -1 })
    .limit(1)
    .toArray();

  let cursor =
    last.length > 0 && typeof last[0]?.position === 'number' ? (last[0].position as number) : 0;

  const seen = new Set<string>();
  const operations: AnyBulkWriteOperation<Document>[] = [];
  const now = new Date();

  for (const entry of tracks) {
    if (seen.has(entry.trackId)) continue;
    seen.add(entry.trackId);
    cursor += POSITION_GAP;
    operations.push({
      updateOne: {
        filter: { ...scope, trackId: entry.trackId } as Filter<Document>,
        update: {
          $set: { ...entry.track, ...scope, trackId: entry.trackId },
          // Position is set only on insert. A track already in the playlist
          // keeps where the user put it — appending a list that happens to
          // contain it must not move it to the end.
          $setOnInsert: { createdAt: now, position: cursor },
        },
        upsert: true,
      },
    });
  }

  if (operations.length === 0) return 0;
  const result = await collection.bulkWrite(operations, { ordered: false });
  return result.upsertedCount + result.modifiedCount;
}

/**
 * Renumbers a whole playlist onto clean, evenly spaced positions.
 *
 * The expensive path, and deliberately so: one write per track, run only when
 * fractional positions have been subdivided to the point of collapse. In
 * exchange every ordinary reorder is a single write.
 */
export async function rebalance(
  collection: Collection<Document>,
  scope: TrackScope,
  orderedTrackIds: string[],
): Promise<void> {
  if (orderedTrackIds.length === 0) return;
  await collection.bulkWrite(
    orderedTrackIds.map((trackId, index) => ({
      updateOne: {
        filter: { ...scope, trackId } as Filter<Document>,
        update: { $set: { position: (index + 1) * POSITION_GAP } },
      },
    })),
    { ordered: false },
  );
}

/**
 * Recomputes `trackCount` on the parent document.
 *
 * A wrong count is a cosmetic subtitle, not a broken playlist — the rows
 * themselves are already written — so a failure here is swallowed by the caller
 * rather than failing the write that preceded it.
 */
export async function syncTrackCount<P extends Document, T extends Document>(
  playlists: Collection<P>,
  tracks: Collection<T>,
  parentFilter: Filter<P>,
  trackScope: TrackScope,
): Promise<number> {
  const count = await tracks.countDocuments(trackScope as Filter<T>);
  // Both playlist collections carry `trackCount` and `updatedAt`; the cast is
  // because the generic parameter cannot express "some document that has these
  // two fields" without constraining every caller to a shared base interface,
  // which would be more ceremony than the one write is worth.
  await playlists.updateOne(parentFilter, {
    $set: { trackCount: count, updatedAt: new Date() } as never,
  });
  return count;
}
