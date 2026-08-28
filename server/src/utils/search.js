/**
 * A faithful port of `song_key.dart` / `SearchTokens` to JavaScript.
 *
 * ## Why this is a port and not a rewrite
 *
 * The token arrays stored on catalogue documents were written by the Dart
 * client, and are still written by it — `Song.fromTrack` computes
 * `searchTokens` before the row is ever sent here. The *query* side now runs on
 * the server, because the client sends a search string and no longer touches
 * the database.
 *
 * Both halves therefore have to normalise identically. If the server's
 * `queryToken('Blinding')` produced `blinding` while the client's tokeniser had
 * stored `blindin`, search would return nothing and look like an empty
 * catalogue. So this file mirrors the Dart source line for line, and the tests
 * in `test/search.test.js` assert the specific pairs where the two
 * implementations could plausibly drift — accent folding, the `feat.` boundary,
 * and stop-word handling.
 *
 * Keep this in step with `lib/data/models/song_key.dart`. It is the one piece
 * of genuinely duplicated logic in the migration, and it is duplicated because
 * the alternative — shipping a normalisation round-trip to the server on every
 * keystroke — costs a request per character.
 */

// ---------------------------------------------------------------------------
// Normalisation
// ---------------------------------------------------------------------------

const PACKAGING = new RegExp(
  '\\b(' +
    'official\\s+(music\\s+)?video|official\\s+audio|official\\s+lyric\\s+video|' +
    'official\\s+visuali[sz]er|official\\s+hd\\s+video|official|' +
    'lyric\\s+video|lyrics\\s+video|with\\s+lyrics|visuali[sz]er|' +
    'music\\s+video|audio\\s+only|full\\s+audio|hq\\s+audio|' +
    'remaster(ed)?(\\s+\\d{4})?|\\d{4}\\s+remaster(ed)?|' +
    'digital\\s+remaster(ed)?|' +
    'explicit|clean\\s+version|' +
    '4k|8k|hd|hq|uhd|' +
    'free\\s+download|out\\s+now' +
    ')\\b',
  'gi',
);

// The word boundary closes before the optional period, for the reason spelled
// out in the Dart original: `\b` sits between a word and a non-word character,
// and "feat." is followed by a space — two non-word characters with no boundary
// between them. Written the other way round this never matches "feat.".
const FEATURING = /\s*[([]?\s*\b(?:feat|ft|featuring)\b\.?\s+[^)\]]*[)\]]?/gi;

const EMPTY_BRACKETS = /[([{]\s*[^A-Za-z0-9]*\s*[)\]}]/g;
const TOPIC_SUFFIX = /\s*-\s*topic\s*$/i;
const VEVO_SUFFIX = /vevo\s*$/i;

const ACCENTS_FROM = 'àáâãäåèéêëìíîïòóôõöùúûüýÿñçšžæøåđłß';
const ACCENTS_TO = 'aaaaaaeeeeiiiiooooouuuuyyncszaoadls';

function foldAccents(value) {
  let out = '';
  for (const char of value) {
    const index = ACCENTS_FROM.indexOf(char);
    out += index === -1 ? char : ACCENTS_TO[index];
  }
  return out;
}

function collapse(value) {
  return value
    .replace(/[^a-z0-9\s]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

export function normaliseTitle(value) {
  let out = foldAccents(String(value ?? '').toLowerCase());
  out = out.replace(FEATURING, ' ');
  out = out.replace(PACKAGING, ' ');
  out = out.replace(EMPTY_BRACKETS, ' ');
  return collapse(out);
}

export function normaliseArtist(value) {
  let out = foldAccents(String(value ?? '').toLowerCase());
  out = out.replace(TOPIC_SUFFIX, ' ');

  // Truncate at the first separator that introduces a *secondary* credit, so
  // "The Weeknd, Daft Punk" and "The Weeknd" resolve to one primary artist.
  const separators = [
    ',',
    '&',
    /\bfeat\.?\b/,
    /\bft\.?\b/,
    /\bfeaturing\b/,
    /\bvs\.?\b/,
    /\bwith\b/,
    /\s+x\s+/,
  ];
  for (const separator of separators) {
    const index =
      typeof separator === 'string' ? out.indexOf(separator) : out.search(separator);
    if (index > 0) out = out.slice(0, index);
  }

  out = out.replace(VEVO_SUFFIX, ' ');
  return collapse(out);
}

export function normaliseAlbum(value) {
  let out = foldAccents(String(value ?? '').toLowerCase());
  out = out.replace(PACKAGING, ' ');
  out = out.replace(EMPTY_BRACKETS, ' ');
  return collapse(out);
}

// ---------------------------------------------------------------------------
// Tokens
// ---------------------------------------------------------------------------

export const MAX_PREFIX = 12;
export const MAX_TOKENS = 180;

const STOP_WORDS = new Set([
  'the', 'a', 'an', 'and', 'or', 'of', 'in', 'on', 'at', 'to', 'for',
]);

function addPrefixes(field, into) {
  for (const word of field.split(' ')) {
    if (!word) continue;
    if (into.size >= MAX_TOKENS) return;

    // A stop word is still indexed in full when it is the entire field — a
    // playlist genuinely called "The" should be findable.
    const skipWhole = STOP_WORDS.has(word) && field !== word;

    const limit = Math.min(word.length, MAX_PREFIX);
    for (let length = 1; length <= limit; length++) {
      if (skipWhole && length === word.length) continue;
      into.add(word.slice(0, length));
      if (into.size >= MAX_TOKENS) return;
    }
  }
}

/** The token set for one catalogue song. Mirrors `SearchTokens.forSong`. */
export function tokensForSong({ title, artist, album = '' }) {
  const tokens = new Set();
  const fields = [
    normaliseTitle(title),
    normaliseArtist(artist),
    // The full credit as well as the primary artist, so searching a featured
    // artist finds the track they appear on.
    collapse(foldAccents(String(artist ?? '').toLowerCase())),
    normaliseAlbum(album),
  ];
  for (const field of fields) {
    addPrefixes(field, tokens);
    if (tokens.size >= MAX_TOKENS) break;
  }
  return [...tokens].slice(0, MAX_TOKENS);
}

/** The token set for a playlist name. Mirrors `SearchTokens.forPlaylist`. */
export function tokensForPlaylist(name) {
  const tokens = new Set();
  addPrefixes(normaliseAlbum(name), tokens);
  return [...tokens].slice(0, MAX_TOKENS);
}

function queryWords(query) {
  return normaliseAlbum(query)
    .split(' ')
    .filter(Boolean)
    .sort((a, b) => b.length - a.length);
}

/**
 * The single token the index is queried on.
 *
 * The *longest* word, because it is the most selective: "blinding lights" hits
 * the index on "blinding", which matches few documents, rather than on
 * "lights", which matches many. The remaining words are applied over the
 * bounded result page by [matchesResidual].
 *
 * This is inherited from the Firestore design — one `array-contains` per query
 * was a hard limit there — and kept here on purpose. Mongo would allow an
 * `$all` over every word, but that changes which documents match: `$all`
 * requires every word to be a token, so a two-word query where the second word
 * is a stop word would return nothing where it previously returned results.
 * Same query, same results, different database.
 */
export function queryToken(query) {
  const words = queryWords(query);
  if (words.length === 0) return '';
  const longest = words[0];
  return longest.length <= MAX_PREFIX ? longest : longest.slice(0, MAX_PREFIX);
}

/** The words a candidate must also contain. Mirrors `SearchTokens.residualWords`. */
export function residualWords(query) {
  const words = queryWords(query);
  return words.length <= 1 ? [] : words.slice(1);
}

/**
 * Whether a candidate row satisfies the words that were not sent to the index.
 *
 * `haystack` is the row's searchable text, already normalised and joined.
 */
export function matchesResidual(haystack, residuals) {
  if (residuals.length === 0) return true;
  return residuals.every((word) => haystack.includes(word));
}
