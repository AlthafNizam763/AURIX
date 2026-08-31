import type { MusicProviderId } from '../../config/env';

/**
 * The provider-neutral shape every fetcher produces and the importer consumes.
 *
 * ## Why normalisation happens here rather than in each provider's writer
 *
 * Spotify and YouTube disagree about almost everything: Spotify has an artist
 * *list* and a real album and an exact duration in milliseconds; YouTube has a
 * channel title, no album at all, and a duration that lives on a different
 * endpoint entirely. If each provider wrote to MongoDB directly, those
 * differences would be spread across two write paths and the catalogue would
 * end up with two shapes of song document.
 *
 * So a fetcher's whole job is to answer *in this shape*, and the importer never
 * learns which provider it is serving. That is what makes `import.ts` one
 * function rather than two, and it is what a third provider would plug into.
 *
 * ## What is deliberately absent
 *
 * There is no audio field, no stream URL, no file handle, and there will not be
 * one. AURIX imports what a playlist *is* — titles, artists, ordering — and not
 * what it sounds like. Both providers' terms forbid the latter and neither
 * offers an endpoint for it. See docs/API_LIMITATIONS.md §1.
 */

/** One track, as the provider describes it. */
export interface ProviderTrack {
  /** The provider's own id. Empty for an entry the provider could not identify. */
  providerTrackId: string;
  title: string;
  /** In order. Spotify gives several; YouTube gives the channel, so exactly one. */
  artists: string[];
  album: string;
  /** Milliseconds. Zero when the provider does not say, which YouTube often does not. */
  durationMs: number;
  artworkUrl: string;
  explicit: boolean;
  /** A link back to the track on the provider. */
  externalUrl: string;
  /** Spotify's 30-second clip, where one is published. Never provider audio. */
  previewUrl?: string;
}

/** A playlist's own metadata. */
export interface ProviderPlaylist {
  providerPlaylistId: string;
  name: string;
  description: string;
  coverUrl: string;
  ownerName: string;
  /**
   * The provider's own count of entries.
   *
   * Advisory, and it is important that it is not written to the database as
   * though it were authoritative: it counts entries this import will legitimately
   * skip — deleted tracks, local files, private videos — so the number of rows
   * actually written can be lower and that is not a bug. `import.ts` recounts
   * from the rows it wrote.
   */
  totalTracks: number;
  externalUrl: string;
}

/** A playlist and every one of its items, fetched whole. */
export interface FetchedPlaylist {
  playlist: ProviderPlaylist;
  tracks: ProviderTrack[];
  /**
   * Entries the provider returned that could not be imported, and why.
   *
   * Surfaced to the user rather than discarded. A playlist of 40 that imports
   * 37 should say so — silently producing 37 is how a library drifts out of
   * agreement with its source without anyone noticing.
   */
  skipped: SkippedEntry[];
  /**
   * True when paging stopped at the safety cap rather than at the end.
   *
   * Reported so the response can say "the first 2,000 of 5,000" instead of
   * quietly truncating.
   */
  truncated: boolean;
}

export interface SkippedEntry {
  position: number;
  reason: 'deleted' | 'local_file' | 'private_video' | 'not_a_track' | 'no_id';
}

/** Who AURIX is acting as when it calls a provider. */
export interface ProviderCredential {
  accessToken: string;
  scopes: string[];
  /** The provider's id for the connected account, for ownership checks. */
  accountId: string;
}

/**
 * What a provider fetcher must implement.
 *
 * [fetch] must page to completion. A fetcher that returns the first page
 * produces a library that silently disagrees with the source, which is the
 * failure this contract exists to forbid — and which the previous Spotify
 * implementation actually shipped.
 */
export interface PlaylistFetcher {
  readonly provider: MusicProviderId;
  /** Human-readable, for error messages: "Spotify", "YouTube". */
  readonly label: string;
  fetch(playlistId: string, credential: ProviderCredential | null): Promise<FetchedPlaylist>;
}
