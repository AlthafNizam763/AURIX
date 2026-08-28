import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import {
  normaliseAlbum,
  normaliseArtist,
  normaliseTitle,
  queryToken,
  residualWords,
  tokensForPlaylist,
  tokensForSong,
} from '../src/utils/search.js';

/**
 * The search tokeniser is a port of `song_key.dart`, and the two halves of
 * search now run on different sides of the network: the client writes the token
 * arrays, the server queries them.
 *
 * These cases are the ones where the two implementations could plausibly drift.
 * A failure here does not look like a crash in production — it looks like an
 * empty catalogue, which is why they are asserted rather than assumed.
 */
describe('normalisation', () => {
  it('strips packaging noise that describes the upload, not the recording', () => {
    assert.equal(
      normaliseTitle('Blinding Lights (Official Video)'),
      'blinding lights',
    );
    assert.equal(normaliseTitle('Bohemian Rhapsody - Remastered 2011'), 'bohemian rhapsody');
    assert.equal(normaliseTitle('Levitating [4K]'), 'levitating');
  });

  it('keeps words that name a different recording', () => {
    // The distinction the whole design rests on: packaging is stripped,
    // a different performance is its own catalogue entry.
    assert.equal(normaliseTitle('Creep (Acoustic)'), 'creep acoustic');
    assert.equal(normaliseTitle('One More Time (Remix)'), 'one more time remix');
    assert.equal(normaliseTitle('Wonderwall - Live'), 'wonderwall live');
  });

  it('drops featured credits, including the "feat." spelling', () => {
    // The word-boundary placement in FEATURING is the subtle part: written the
    // other way round the pattern never matches "feat." at all.
    assert.equal(normaliseTitle('Starboy feat. Daft Punk'), 'starboy');
    assert.equal(normaliseTitle('Starboy (feat. Daft Punk)'), 'starboy');
    assert.equal(normaliseTitle('Starboy ft Daft Punk'), 'starboy');
    assert.equal(normaliseTitle('Starboy featuring Daft Punk'), 'starboy');
  });

  it('does not treat "with" as a credit marker in a title', () => {
    // "with" is an ordinary English word in a title, and treating it as a
    // credit would truncate real titles at their midpoint.
    assert.equal(normaliseTitle('Dancing With Myself'), 'dancing with myself');
  });

  it('folds accents so the same song from two services converges', () => {
    assert.equal(normaliseTitle('Déjà Vu'), 'deja vu');
    assert.equal(normaliseArtist('Beyoncé'), 'beyonce');
    assert.equal(normaliseArtist('Sigur Rós'), 'sigur ros');
  });

  it('reduces an artist credit to the primary artist', () => {
    assert.equal(normaliseArtist('The Weeknd, Daft Punk'), 'the weeknd');
    assert.equal(normaliseArtist('The Weeknd & Daft Punk'), 'the weeknd');
    assert.equal(normaliseArtist('The Weeknd feat. Daft Punk'), 'the weeknd');
    assert.equal(normaliseArtist('Martin Garrix x Bebe Rexha'), 'martin garrix');
  });

  it('strips the YouTube channel markers', () => {
    assert.equal(normaliseArtist('The Weeknd - Topic'), 'the weeknd');
    assert.equal(normaliseArtist('TheWeekndVEVO'), 'theweeknd');
  });
});

describe('tokens', () => {
  it('indexes every prefix of every word, so a mid-title word is findable', () => {
    // The property a range scan could not give: "lights" must find
    // "Blinding Lights".
    const tokens = tokensForSong({ title: 'Blinding Lights', artist: 'The Weeknd' });
    assert.ok(tokens.includes('l'));
    assert.ok(tokens.includes('lig'));
    assert.ok(tokens.includes('lights'));
    assert.ok(tokens.includes('blinding'));
  });

  it('excludes a stop word as a whole token but keeps its prefixes', () => {
    const tokens = tokensForSong({ title: 'The Chain', artist: 'Fleetwood Mac' });
    assert.ok(!tokens.includes('the'), '"the" must not match every song');
    assert.ok(tokens.includes('th'));
    assert.ok(tokens.includes('chain'));
  });

  it('indexes a stop word in full when it is the entire field', () => {
    // A playlist genuinely called "The" should still be findable.
    assert.ok(tokensForPlaylist('The').includes('the'));
  });

  it('caps prefixes at twelve characters', () => {
    const tokens = tokensForSong({ title: 'Supercalifragilistic', artist: 'X' });
    assert.ok(tokens.includes('supercalifra'));
    assert.ok(!tokens.includes('supercalifrag'));
  });

  it('bounds the array so a pathological title cannot bloat a document', () => {
    const long = Array.from({ length: 200 }, (_, i) => `word${i}`).join(' ');
    assert.ok(tokensForSong({ title: long, artist: long }).length <= 180);
  });
});

describe('query planning', () => {
  it('sends the most selective word to the index', () => {
    // "blinding" matches few documents; "lights" matches many.
    assert.equal(queryToken('blinding lights'), 'blinding');
    assert.deepEqual(residualWords('blinding lights'), ['lights']);
  });

  it('truncates a long query word to the indexed prefix length', () => {
    assert.equal(queryToken('supercalifragilistic'), 'supercalifra');
  });

  it('returns nothing indexable for a query with no letters or digits', () => {
    assert.equal(queryToken('   ...   '), '');
    assert.equal(queryToken(''), '');
  });

  it('matches what the writer indexed, for the same input', () => {
    // The round trip that matters: whatever the client stored, the server's
    // query token must be one of those strings.
    const tokens = tokensForSong({ title: 'Blinding Lights', artist: 'The Weeknd' });
    for (const query of ['blin', 'blinding', 'Blinding', 'BLINDING']) {
      assert.ok(
        tokens.includes(queryToken(query)),
        `"${query}" produced a token the writer never stored`,
      );
    }
  });

  it('normalises a query the same way it normalises stored text', () => {
    assert.equal(normaliseAlbum('Déjà Vu'), 'deja vu');
    assert.ok(tokensForSong({ title: 'Déjà Vu', artist: 'X' }).includes(queryToken('deja')));
  });
});
