import { collections } from '../db/mongo';
import { log } from '../utils/logger';
import { syncTrackCount } from './playlists';

/**
 * Helpers for the shared imported catalogue.
 *
 * ## The one thing to keep straight about this collection
 *
 * `globalPlaylists` is **shared**. A playlist imported by one user is findable
 * and playable by every user — that is what makes an import a contribution to
 * AURIX rather than a private copy. So no read here is narrowed by a uid.
 *
 * Provenance is recorded (`importedByUserId`, `importedBy`, `importedAt`) and
 * only ever *enforces* in one place: `DELETE`, where the importer alone may
 * remove what they added. Recorded, not enforcing, everywhere else.
 */

/** The number of index candidates fetched per residual-word query. */
export const SEARCH_FANOUT = 4;

/**
 * Recomputes `trackCount` after a track mutation.
 *
 * Swallows its failure for the same reason the user-playlist version does: the
 * rows are already written and a stale count is cosmetic.
 */
export async function recount(playlistId: string): Promise<void> {
  try {
    const playlists = await collections.globalPlaylists();
    const tracks = await collections.globalPlaylistTracks();
    await syncTrackCount(playlists, tracks, { _id: playlistId }, { playlistId });
  } catch (error) {
    log.warn(`Could not sync shared track count for ${playlistId}`, 'import', error);
  }
}
