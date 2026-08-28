import assert from 'node:assert/strict';
import { describe, it } from 'node:test';

import { COLOR_KEYS, DEFAULT_THEME, normalise, themeOut } from '../src/services/theme.js';
import { positionBetween, POSITION_GAP } from '../src/services/playlists.js';

/**
 * The theme document is the one piece of data that can make the app *unusable*
 * rather than merely incomplete — a null background paints black on black. So
 * the guarantee under test is not "valid input produces valid output" but
 * "**no** input produces invalid output".
 */
describe('theme normalisation', () => {
  it('fills every field from an empty document', () => {
    const theme = normalise({});
    assert.equal(theme.fontFamily, DEFAULT_THEME.fontFamily);
    for (const mode of ['dark', 'light']) {
      for (const key of COLOR_KEYS) {
        assert.match(theme.colors[mode][key], /^#[0-9A-F]{6,8}$/, `${mode}.${key}`);
      }
    }
    for (const surface of ['mini', 'large', 'outside', 'dynamic']) {
      assert.equal(theme.musicPlayer[surface], 'theme1');
    }
  });

  it('replaces an unusable colour with the default rather than passing it through', () => {
    const theme = normalise({
      colors: { dark: { background: 'not-a-colour', surface: '#12345', text: null } },
    });
    assert.equal(theme.colors.dark.background, DEFAULT_THEME.colors.dark.background);
    assert.equal(theme.colors.dark.surface, DEFAULT_THEME.colors.dark.surface);
    assert.equal(theme.colors.dark.text, DEFAULT_THEME.colors.dark.text);
  });

  it('accepts both #RRGGBB and #AARRGGBB, and upper-cases them', () => {
    const theme = normalise({ colors: { dark: { accent: '#e50914', player: '#80ff0000' } } });
    assert.equal(theme.colors.dark.accent, '#E50914');
    assert.equal(theme.colors.dark.player, '#80FF0000');
  });

  it('clamps typography rather than letting it break the scale', () => {
    const theme = normalise({ typography: { scale: 9, letterSpacing: -50, weightBold: 5000 } });
    assert.equal(theme.typography.scale, 1.4);
    assert.equal(theme.typography.letterSpacing, -1);
    assert.equal(theme.typography.weightBold, 900);
  });

  it('rejects an unknown player variant instead of storing it', () => {
    // A variant the app has no widget for would render nothing at all.
    const theme = normalise({ musicPlayer: { mini: 'theme9', large: 'theme3' } });
    assert.equal(theme.musicPlayer.mini, 'theme1');
    assert.equal(theme.musicPlayer.large, 'theme3');
  });

  it('mirrors the dark colourway onto the flat configuration keys', () => {
    // The documented configuration format is flat; the app applies the nested
    // form. Both must describe the same colours.
    const out = themeOut({ colors: { dark: { background: '#101010', accent: '#E50914' } } });
    assert.equal(out.backgroundColor, '#101010');
    assert.equal(out.accentColor, '#E50914');
    assert.equal(out.backgroundColor, out.colors.dark.background);
  });
});

/**
 * Fractional positions are what make a drag one write instead of N. The
 * collapse case is the one worth a test — it takes about fifty real reorders
 * between the same pair to reach through the UI.
 */
describe('playlist positions', () => {
  it('spaces the first track by the gap', () => {
    assert.equal(positionBetween(null, null), POSITION_GAP);
  });

  it('appends after the last and prepends before the first', () => {
    assert.equal(positionBetween(2048, null), 2048 + POSITION_GAP);
    assert.equal(positionBetween(null, 1024), 1024 - POSITION_GAP);
  });

  it('takes the midpoint between two neighbours', () => {
    assert.equal(positionBetween(1024, 2048), 1536);
  });

  it('reports collapse instead of returning a position that cannot separate', () => {
    // The signal to renumber the list once, after which the move is
    // expressible again.
    assert.equal(positionBetween(1024, 1024.00001), null);
    assert.equal(positionBetween(1024, 1024), null);
  });

  it('subdivides ~24 times at one spot, then asks for a renumber', () => {
    // The worst case: every drop lands immediately after the same track, so
    // the gap halves each time. 1024 / 2^n < 0.0001 at n = 24, which is the
    // real depth — the doc comment on the Dart original says "fifty", and that
    // figure is only reachable when the drops are spread across the list.
    //
    // What matters is not the exact number but that the collapse is *reported*
    // rather than silently returning two tracks the same position, which would
    // make the ordering depend on Mongo's tie-break.
    let before = 1024;
    const after = 2048;
    let depth = 0;

    for (;;) {
      const next = positionBetween(before, after);
      if (next === null) break;
      assert.ok(next > before && next < after, 'a midpoint must separate its neighbours');
      before = next;
      depth++;
      if (depth > 100) break;
    }

    assert.ok(depth >= 20, `expected at least 20 subdivisions, got ${depth}`);
    assert.ok(depth <= 30, `expected collapse to be detected by 30, got ${depth}`);
  });
});
