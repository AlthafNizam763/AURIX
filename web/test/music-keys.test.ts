import crypto from 'node:crypto';

import { describe, expect, it } from 'vitest';

import { metadataKey, playlistKey, trackKey } from '@/server/services/music/keys';
import { open, seal } from '@/server/services/music/crypto';

/**
 * The deduplication contract.
 *
 * Both ids are derived rather than generated, which is the whole of §7: the
 * same playlist imported twice writes to one document, and a song already in the
 * catalogue is reused instead of duplicated. There is no "have I seen this?"
 * query holding that together — the key *is* the answer.
 *
 * The vectors below are also the parity check against
 * `mobile/lib/data/models/playlist_key.dart` and `track_key.dart`. The client
 * derives ids for playlists built in AURIX and the server derives them for
 * playlists imported into it; if the two ever disagreed, the same Spotify
 * playlist would occupy one document from one path and a different one from the
 * other, and the duplicate prevention would quietly stop working.
 */

describe('playlist ids', () => {
  it('is stable for the same provider and id', () => {
    expect(playlistKey('spotify', '22WMPdyCLdKfeRraLxZbMw')).toBe(
      'pl_spotify_22WMPdyCLdKfeRraLxZbMw',
    );
    expect(playlistKey('spotify', '22WMPdyCLdKfeRraLxZbMw')).toBe(
      playlistKey('spotify', '22WMPdyCLdKfeRraLxZbMw'),
    );
  });

  it('qualifies by provider, so two services cannot collide', () => {
    expect(playlistKey('spotify', 'abc')).not.toBe(playlistKey('youtube', 'abc'));
  });

  it('carries the prefix that marks a shared-catalogue playlist', () => {
    // `PlaylistKey.isGlobal` on the client tests exactly this prefix to decide
    // which collection a bare id addresses.
    expect(playlistKey('youtube', 'PLabc')).toMatch(/^pl_/);
  });

  it('hashes an id that would not be safe as a document id', () => {
    const key = playlistKey('spotify', 'has spaces/and slashes');
    expect(key.startsWith('pl_spotify_')).toBe(true);
    // SHA-1, first 24 hex characters — the same derivation as `PlaylistKey._hash`.
    const expected = crypto
      .createHash('sha1')
      .update('has spaces/and slashes', 'utf8')
      .digest('hex')
      .slice(0, 24);
    expect(key).toBe(`pl_spotify_${expected}`);
  });
});

describe('track ids', () => {
  it('is `<provider>_<id>`', () => {
    expect(trackKey('spotify', '4uLU6hMCjMI75M1A2tKUQC')).toBe('spotify_4uLU6hMCjMI75M1A2tKUQC');
    expect(trackKey('youtube', 'dQw4w9WgXcQ')).toBe('youtube_dQw4w9WgXcQ');
  });

  it('qualifies by provider', () => {
    // The bug this prevents: two services handing out the same id string would
    // otherwise merge two different songs into one catalogue document.
    expect(trackKey('spotify', 'abc')).not.toBe(trackKey('youtube', 'abc'));
  });

  it('sanitises the way the client does', () => {
    // `TrackKey._sanitize`: non-id characters become hyphens, runs collapse,
    // leading and trailing hyphens go.
    expect(trackKey('spotify', 'a b//c')).toBe('spotify_a-b-c');
  });

  it('falls back to title and artist when the provider gave no id', () => {
    expect(metadataKey('Bohemian Rhapsody', 'Queen')).toBe('aurix_bohemian-rhapsody-queen');
  });

  it('collapses trivial spacing and case differences in the fallback', () => {
    // Otherwise the same song imported twice from two id-less sources becomes
    // two library rows.
    expect(metadataKey('The  Weeknd', 'x')).toBe(metadataKey('the weeknd', 'X'));
  });

  it('never produces an empty id', () => {
    expect(metadataKey('', '')).toBe('aurix_untitled');
  });
});

describe('token encryption', () => {
  it('round-trips a refresh token', () => {
    const token = 'AQD-x'.repeat(40);
    expect(open(seal(token))).toBe(token);
  });

  it('produces a different ciphertext each time', () => {
    // A fresh IV per seal. Identical ciphertexts would leak that two users hold
    // the same token, and would be a nonce reuse in GCM.
    expect(seal('same')).not.toBe(seal('same'));
  });

  it('refuses a tampered value rather than returning rubbish', () => {
    const sealed = seal('token');
    const parts = sealed.split('.');
    parts[3] = Buffer.from('substituted').toString('base64url');
    // GCM authenticates as well as encrypts, which is the reason for choosing
    // it: a value about to be sent to Google as a credential must not be
    // attacker-chooseable.
    expect(open(parts.join('.'))).toBeNull();
  });

  it('returns null rather than throwing on anything unreadable', () => {
    // The realistic cause is a rotated MUSIC_TOKEN_KEY, which makes every
    // stored connection unreadable at once. That has to become "reconnect
    // Spotify", not a 500 on the import screen.
    expect(open('not-sealed')).toBeNull();
    expect(open('')).toBeNull();
    expect(open(undefined)).toBeNull();
    expect(open('v2.a.b.c')).toBeNull();
  });
});
