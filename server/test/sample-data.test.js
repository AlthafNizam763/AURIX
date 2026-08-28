import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  ALBUMS,
  DEMO_ID_PREFIX,
  GENRES,
  PLAYLISTS,
  SONGS,
} from '../scripts/sample-data/catalogue.js';
import { queryToken, residualWords, matchesResidual, tokensForSong } from '../src/utils/search.js';

/**
 * The demo catalogue's internal consistency, checked without the network.
 *
 * `seed-samples.js` verifies that the URLs answer; that needs Wikimedia and a
 * dozen seconds, so it belongs in the seed rather than in a unit test. What is
 * checked here is everything that can be wrong *without* the network being
 * involved — a duplicated id, a playlist pointing at a song that was renamed,
 * a track whose title cannot be found by the search the app actually runs.
 *
 * These are the failures that do not look like failures. A playlist with a
 * mistyped song id seeds successfully and simply comes out one track short; a
 * song whose tokens disagree with the query normaliser seeds successfully and
 * is simply never found. Both are silent in production and loud here.
 */

describe('demo catalogue shape', () => {
  it('gives every song a unique, prefixed id', () => {
    const ids = SONGS.map((song) => song.id);
    assert.equal(new Set(ids).size, ids.length, 'duplicate song id');
    for (const id of ids) assert.ok(id.startsWith(DEMO_ID_PREFIX), `${id} is not prefixed`);
  });

  it('gives every playlist a unique, prefixed id', () => {
    const ids = PLAYLISTS.map((playlist) => playlist.id);
    assert.equal(new Set(ids).size, ids.length, 'duplicate playlist id');
    for (const id of ids) assert.ok(id.startsWith(DEMO_ID_PREFIX), `${id} is not prefixed`);
  });

  it('fills every field the catalogue document needs', () => {
    for (const song of SONGS) {
      assert.ok(song.title.trim(), `${song.id} has no title`);
      assert.ok(song.artists.length > 0, `${song.id} has no artist`);
      assert.ok(song.artists.every((name) => name.trim()), `${song.id} has a blank artist`);
      assert.ok(song.album?.name?.trim(), `${song.id} has no album`);
      assert.ok(song.album?.artwork?.startsWith('https://'), `${song.id} has no artwork`);
      // Duration drives the scrubber and the auto-advance. Zero is the value
      // that makes a player look broken rather than throw.
      assert.ok(song.durationMs > 0, `${song.id} has no duration`);
    }
  });
});

describe('licensing', () => {
  /**
   * The rule this whole fixture exists to respect. A demo track with no
   * recorded licence is the one most likely to be some file somebody found,
   * which is exactly what AURIX must never stream.
   */
  it('records a licence and an attribution for every recording', () => {
    for (const song of SONGS) {
      assert.ok(song.license?.trim(), `${song.id} has no licence`);
      assert.ok(song.attribution?.trim(), `${song.id} has no attribution`);
    }
  });

  it('uses only public-domain or Creative Commons audio', () => {
    const permitted = /^(public domain|public domain mark|cc0|cc by)/i;
    for (const song of SONGS) {
      assert.match(song.license, permitted, `${song.id} carries licence "${song.license}"`);
    }
  });

  it('streams only from Wikimedia, and never claims a provider id', () => {
    for (const song of SONGS) {
      assert.ok(
        song.previewUrl.startsWith('https://upload.wikimedia.org/'),
        `${song.id} streams from outside Wikimedia`,
      );
      // A demo row that carried one of these would be picked up by the
      // resolver as a Spotify or YouTube track and would send the player
      // looking for a provider that has never heard of it.
      assert.equal(song.spotifyId, undefined, `${song.id} claims a Spotify id`);
      assert.equal(song.youtubeVideoId, undefined, `${song.id} claims a YouTube id`);
    }
  });

  it('asks for an MP3 rather than the Ogg original', () => {
    // Android plays Ogg and iOS does not, so a `.ogg` here is a catalogue that
    // works on half the devices — and works on the half a developer is most
    // likely to be holding.
    for (const song of SONGS) {
      assert.ok(song.previewUrl.endsWith('.mp3'), `${song.id} is not an MP3`);
    }
  });
});

describe('genres and albums', () => {
  it('tags every song with a genre from the vocabulary', () => {
    const known = new Set(GENRES.map((genre) => genre.id));
    for (const song of SONGS) {
      assert.ok(known.has(song.genre), `${song.id} has unknown genre ${song.genre}`);
    }
  });

  it('leaves no genre without a song', () => {
    const used = new Set(SONGS.map((song) => song.genre));
    for (const genre of GENRES) {
      assert.ok(used.has(genre.id), `genre ${genre.id} has no songs`);
    }
  });

  it('leaves no album without a song', () => {
    const used = new Set(SONGS.map((song) => song.album.name));
    for (const album of Object.values(ALBUMS)) {
      assert.ok(used.has(album.name), `album "${album.name}" has no songs`);
    }
  });

  it('gives one album exactly one cover', () => {
    const covers = new Map();
    for (const song of SONGS) {
      const seen = covers.get(song.album.name);
      if (seen) assert.equal(seen, song.album.artwork, `${song.album.name} has two covers`);
      else covers.set(song.album.name, song.album.artwork);
    }
  });
});

describe('playlists', () => {
  it('references only songs that exist', () => {
    const ids = new Set(SONGS.map((song) => song.id));
    for (const playlist of PLAYLISTS) {
      for (const id of playlist.songs) {
        assert.ok(ids.has(id), `${playlist.id} references unknown song ${id}`);
      }
    }
  });

  it('lists no song twice within one playlist', () => {
    // `writeTracksInOrder` collapses duplicates, so a repeat would not corrupt
    // the database — it would silently shorten the playlist, which is worse.
    for (const playlist of PLAYLISTS) {
      assert.equal(
        new Set(playlist.songs).size,
        playlist.songs.length,
        `${playlist.id} repeats a song`,
      );
    }
  });

  it('carries a name, a description and a cover', () => {
    for (const playlist of PLAYLISTS) {
      assert.ok(playlist.name.trim(), `${playlist.id} has no name`);
      assert.ok(playlist.description.trim(), `${playlist.id} has no description`);
      assert.ok(playlist.cover?.startsWith('https://'), `${playlist.id} has no cover`);
      assert.ok(playlist.songs.length > 0, `${playlist.id} is empty`);
    }
  });

  it('leaves no song out of every playlist', () => {
    // Not a correctness requirement, but a coverage one: a song no playlist
    // contains is a song the playlist screens never render, so it is only ever
    // exercised through search.
    const inPlaylists = new Set(PLAYLISTS.flatMap((playlist) => playlist.songs));
    for (const song of SONGS) {
      assert.ok(inPlaylists.has(song.id), `${song.id} is in no playlist`);
    }
  });
});

describe('searchability', () => {
  /**
   * The end-to-end property, run through the real query path.
   *
   * `tokensForSong` writes the array and `queryToken` + `matchesResidual` read
   * it — the same two halves the seed and the search route use. Asserting they
   * meet on this data is what makes "the demo songs appear in search" a tested
   * claim rather than an assumption.
   */
  function findable(song, query) {
    const tokens = tokensForSong({
      title: song.title,
      artist: song.artists.join(', '),
      album: song.album.name,
    });
    const token = queryToken(query);
    if (!token || !tokens.includes(token)) return false;
    const haystack = `${song.title} ${song.artists.join(', ')} ${song.album.name}`.toLowerCase();
    return matchesResidual(haystack, residualWords(query));
  }

  it('finds a song by its title', () => {
    const song = SONGS.find((s) => s.id === 'aurix-demo-goldkette-clementine');
    assert.ok(findable(song, 'Clementine'));
    assert.ok(findable(song, 'clem'));
  });

  it('finds a song by its artist, including a featured one', () => {
    const song = SONGS.find((s) => s.id === 'aurix-demo-goldkette-clementine');
    assert.ok(findable(song, 'Goldkette'));
    assert.ok(findable(song, 'Beiderbecke'), 'the featured credit should be searchable');
  });

  it('finds a song by its album', () => {
    const song = SONGS.find((s) => s.id === 'aurix-demo-bach-goldberg-aria');
    assert.ok(findable(song, 'Baroque Masters'));
  });

  it('gives every song at least one token a user would plausibly type', () => {
    // Stop words are skipped, and that is the tokeniser working rather than
    // failing: "in", "the" and friends are indexed only as prefixes, never as
    // whole words, so that a search for "the" does not return the catalogue.
    // "In the Steppes of Central Asia" is therefore found by "Steppes", which
    // is what anyone actually types.
    const STOP = new Set(['the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'for']);

    for (const song of SONGS) {
      const word = song.title
        .split(/\s+/)
        .map((part) => part.replace(/[^A-Za-z0-9]/g, ''))
        .find((part) => part.length > 1 && !STOP.has(part.toLowerCase()));
      if (!word) continue;
      assert.ok(findable(song, word), `${song.id} is not findable by "${word}"`);
    }
  });

  it('stays within the token cap that the index is sized for', () => {
    for (const song of SONGS) {
      const tokens = tokensForSong({
        title: song.title,
        artist: song.artists.join(', '),
        album: song.album.name,
      });
      assert.ok(tokens.length <= 180, `${song.id} produced ${tokens.length} tokens`);
      // 200 is the route schema's cap. Exceeding it would be rejected on write.
      assert.ok(tokens.length <= 200);
    }
  });
});
