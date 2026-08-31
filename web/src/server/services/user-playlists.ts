import crypto from 'node:crypto';

import type { Document } from 'mongodb';

import { collections } from '../db/mongo';
import { notFound } from '../utils/errors';
import { log } from '../utils/logger';
import { syncTrackCount } from './playlists';

/**
 * Helpers shared by the user-playlist routes.
 *
 * Express kept these at the top of one 398-line router file. The App Router
 * splits that file into eight, so anything more than one of them needs lives
 * here rather than being copied — the same reasoning that put the ordering
 * mechanics in `services/playlists`.
 */

/** A 20-character url-safe id, matching what the Express server minted. */
export const newPlaylistId = (): string =>
  crypto.randomBytes(15).toString('base64url').slice(0, 20);

/**
 * The filter that scopes every track query to one playlist of one user.
 *
 * The uid comes from the verified token, never from the request — which is what
 * makes another account's playlist not merely forbidden but unaddressable.
 */
export const scopeOf = (uid: string, playlistId: string) => ({ uid, playlistId });

/** The playlist, or a 404. Asserts ownership by including the uid in the filter. */
export async function requirePlaylist(uid: string, playlistId: string): Promise<Document> {
  const playlists = await collections.userPlaylists();
  const doc = await playlists.findOne({ uid, playlistId });
  if (!doc) throw notFound('That playlist no longer exists.');
  return doc;
}

/**
 * Recomputes `trackCount` after a track mutation.
 *
 * A wrong count is a cosmetic subtitle, not a broken playlist — the rows
 * themselves are already written — so a failure is logged rather than failing
 * the write that preceded it.
 *
 * Awaited rather than detached, unlike the history trim. It is a single indexed
 * count and the number is read by the very next screen the user sees, so
 * deferring it would show a stale count more often than it would save time.
 */
export async function recount(uid: string, playlistId: string): Promise<void> {
  try {
    const playlists = await collections.userPlaylists();
    const tracks = await collections.userPlaylistTracks();
    await syncTrackCount(playlists, tracks, { uid, playlistId }, scopeOf(uid, playlistId));
  } catch (error) {
    log.warn(`Could not sync track count for ${playlistId}`, 'playlists', error);
  }
}
