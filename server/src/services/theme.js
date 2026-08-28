import { collections } from '../db/mongo.js';
import { THEME_DOC_ID } from '../db/collections.js';
import { iso } from '../utils/async.js';

/**
 * The application theme — one document, read by every client on launch.
 *
 * ## Why a singleton document rather than a settings collection
 *
 * Because the theme is one thing. It is fetched on the cold-start path, before
 * the first frame, by every install; making it a single `_id: 'theme'` document
 * means that fetch is a primary-key lookup and the whole configuration arrives
 * in one round trip. A collection of key/value rows would turn the same fetch
 * into a scan and a client-side reassembly, and would make "apply these six
 * changes atomically" impossible.
 *
 * ## `version` is the cache key
 *
 * Bumped on every write. The client stores the config it last applied along
 * with its version, and on launch it renders from that cached copy *first* and
 * reconciles with the server afterwards — so a cold start never blocks on the
 * network, and a changed theme lands on the next frame after the response
 * arrives. Without a version the client would have to deep-compare two config
 * objects to decide whether to rebuild the whole widget tree.
 *
 * ## Fallbacks are structural, not defensive
 *
 * [DEFAULT_THEME] is the AURIX identity as shipped, and every field is
 * defaulted individually in [normalise]. A config missing `surfaceColor`
 * because it was written by an older admin build renders with the default
 * surface rather than with a null that paints black-on-black. This matters more
 * than usual here: a theme document is the one piece of data that can make the
 * app unusable rather than merely incomplete.
 */

/** Every colour role the admin can set. The order is the order the UI shows. */
export const COLOR_KEYS = [
  'primary',
  'secondary',
  'accent',
  'background',
  'surface',
  'text',
  'player',
  'button',
];

/**
 * The AURIX defaults — the monochrome identity, unchanged.
 *
 * These mirror `AurixPalette.dark` and `AurixPalette.light` exactly, so a
 * deployment that has never touched the admin panel renders pixel-for-pixel
 * what the app shipped with. The Dart side carries the same constants in
 * `ThemeConfig.fallback`, which is what makes the app render correctly with no
 * server at all.
 */
export const DEFAULT_THEME = Object.freeze({
  version: 1,
  fontFamily: 'Manrope',
  fontAssetId: null,

  typography: {
    // A multiplier on every size in the scale rather than a set of absolute
    // sizes: the scale's *proportions* are the design, and letting an admin
    // set fifteen independent point sizes would let them break the hierarchy
    // that makes the app readable.
    scale: 1,
    letterSpacing: 0,
    weightRegular: 400,
    weightMedium: 600,
    weightBold: 700,
    weightDisplay: 800,
  },

  colors: {
    dark: {
      primary: '#FFFFFF',
      secondary: '#222222',
      accent: '#FFFFFF',
      background: '#000000',
      surface: '#151515',
      text: '#FFFFFF',
      player: '#0D0D0D',
      button: '#FFFFFF',
    },
    light: {
      primary: '#0A0A0A',
      secondary: '#FFFFFF',
      accent: '#0A0A0A',
      background: '#F2F2F2',
      surface: '#FFFFFF',
      text: '#0A0A0A',
      player: '#FAFAFA',
      button: '#0A0A0A',
    },
  },

  appLogo: null,
  appIcon: null,

  musicPlayer: { mini: 'theme1', large: 'theme1', outside: 'theme1', dynamic: 'theme1' },
});

/** The player surfaces, and the variants each accepts. */
export const PLAYER_SURFACES = ['mini', 'large', 'outside', 'dynamic'];
export const PLAYER_VARIANTS = ['theme1', 'theme2', 'theme3', 'theme4'];

/**
 * The font families the admin panel offers.
 *
 * `bundled` families ship inside the app and always work, offline included —
 * which is every family below. A non-bundled entry would need a font file
 * uploaded through the admin panel, which the client loads at runtime and
 * caches on the device — see `FontRegistry` on the Dart side. Listing a family
 * with no file is not a broken state: the picker marks it as needing an upload
 * and the app keeps its current face until one arrives.
 */
export const FONT_CATALOGUE = [
  { family: 'Manrope', bundled: true, note: 'The AURIX brand face.' },
  { family: 'Poppins', bundled: true, note: 'Geometric and round.' },
  { family: 'Inter', bundled: true, note: 'Neutral UI face; excellent at small sizes.' },
  { family: 'Roboto', bundled: true, note: 'The Android system face.' },
  { family: 'Montserrat', bundled: true, note: 'Wide and editorial.' },
  { family: 'Oswald', bundled: true, note: 'Condensed; strong for headings.' },
];

const HEX = /^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

/** A hex colour, or the fallback when the stored value is unusable. */
function colour(value, fallback) {
  if (typeof value !== 'string') return fallback;
  const trimmed = value.trim();
  if (!HEX.test(trimmed)) return fallback;
  return trimmed.toUpperCase();
}

function num(value, fallback, { min, max }) {
  const parsed = typeof value === 'number' ? value : Number.parseFloat(value);
  if (!Number.isFinite(parsed)) return fallback;
  return Math.min(max, Math.max(min, parsed));
}

/**
 * Fills every gap in a stored theme from [DEFAULT_THEME].
 *
 * Runs on read as well as on write, so a document written by an older build —
 * or hand-edited in a Mongo shell — can never produce a partial config on the
 * client. The client defaults again on its own side; that redundancy is
 * deliberate, because the app must also survive the server being unreachable.
 */
export function normalise(stored = {}) {
  const typography = stored.typography ?? {};
  const colors = stored.colors ?? {};
  const player = stored.musicPlayer ?? {};

  const paletteFor = (mode) => {
    const source = colors[mode] ?? {};
    const defaults = DEFAULT_THEME.colors[mode];
    return Object.fromEntries(
      COLOR_KEYS.map((key) => [key, colour(source[key], defaults[key])]),
    );
  };

  return {
    version: Number.isInteger(stored.version) ? stored.version : DEFAULT_THEME.version,
    fontFamily:
      typeof stored.fontFamily === 'string' && stored.fontFamily.trim()
        ? stored.fontFamily.trim()
        : DEFAULT_THEME.fontFamily,
    fontAssetId: stored.fontAssetId ?? null,

    typography: {
      scale: num(typography.scale, DEFAULT_THEME.typography.scale, { min: 0.8, max: 1.4 }),
      letterSpacing: num(typography.letterSpacing, DEFAULT_THEME.typography.letterSpacing, {
        min: -1,
        max: 2,
      }),
      weightRegular: num(typography.weightRegular, DEFAULT_THEME.typography.weightRegular, {
        min: 100,
        max: 900,
      }),
      weightMedium: num(typography.weightMedium, DEFAULT_THEME.typography.weightMedium, {
        min: 100,
        max: 900,
      }),
      weightBold: num(typography.weightBold, DEFAULT_THEME.typography.weightBold, {
        min: 100,
        max: 900,
      }),
      weightDisplay: num(typography.weightDisplay, DEFAULT_THEME.typography.weightDisplay, {
        min: 100,
        max: 900,
      }),
    },

    colors: { dark: paletteFor('dark'), light: paletteFor('light') },

    appLogo: typeof stored.appLogo === 'string' && stored.appLogo ? stored.appLogo : null,
    appIcon: typeof stored.appIcon === 'string' && stored.appIcon ? stored.appIcon : null,

    musicPlayer: Object.fromEntries(
      PLAYER_SURFACES.map((surface) => [
        surface,
        PLAYER_VARIANTS.includes(player[surface])
          ? player[surface]
          : DEFAULT_THEME.musicPlayer[surface],
      ]),
    ),

    updatedAt: iso(stored.updatedAt),
    updatedBy: stored.updatedBy ?? null,
  };
}

/**
 * The wire shape.
 *
 * Carries the canonical `colors.{dark,light}` structure *and* mirrors the dark
 * colourway onto the flat `primaryColor` / `backgroundColor` / … keys. The flat
 * keys are the shape the configuration was specified in, so an integration that
 * reads them keeps working; the nested form is what the app applies, because a
 * theme with no light colourway would leave light mode unstyled.
 */
export function themeOut(stored) {
  const theme = normalise(stored);
  const dark = theme.colors.dark;

  return {
    ...theme,
    primaryColor: dark.primary,
    secondaryColor: dark.secondary,
    accentColor: dark.accent,
    backgroundColor: dark.background,
    surfaceColor: dark.surface,
    textColor: dark.text,
    playerColor: dark.player,
    buttonColor: dark.button,
  };
}

/** Reads the theme, creating the default document on first ever call. */
export async function readTheme() {
  const stored = await collections.appConfig().findOne({ _id: THEME_DOC_ID });
  if (stored) return stored;

  const seeded = { _id: THEME_DOC_ID, ...DEFAULT_THEME, updatedAt: new Date(), updatedBy: null };
  // Upsert rather than insert: two cold clients hitting `GET /theme` at the
  // same moment on a fresh deployment would otherwise race, and one would get
  // a duplicate-key error on the very first request the app ever makes.
  await collections
    .appConfig()
    .updateOne({ _id: THEME_DOC_ID }, { $setOnInsert: seeded }, { upsert: true });
  return seeded;
}

/**
 * Applies a patch and bumps the version.
 *
 * The whole normalised document is written rather than a `$set` of the changed
 * keys. That costs nothing at this size and buys a real property: the stored
 * document is always complete and always valid, so a reader never has to
 * distinguish "this field was never set" from "this field was set to null".
 */
export async function writeTheme(patch, { uid } = {}) {
  const current = normalise(await readTheme());
  const merged = normalise(mergePatch(current, patch));

  const doc = {
    ...merged,
    version: current.version + 1,
    updatedAt: new Date(),
    updatedBy: uid ?? null,
  };

  await collections
    .appConfig()
    .updateOne({ _id: THEME_DOC_ID }, { $set: doc }, { upsert: true });

  return doc;
}

/**
 * Folds a patch into the current theme.
 *
 * Accepts both shapes — the nested `colors.dark.primary` and the flat
 * `primaryColor` — because the admin panel sends the first and the documented
 * configuration format uses the second. Flat keys apply to the dark colourway,
 * which is what they describe in the specification's example.
 */
function mergePatch(current, patch = {}) {
  const flatToDark = {
    primaryColor: 'primary',
    secondaryColor: 'secondary',
    accentColor: 'accent',
    backgroundColor: 'background',
    surfaceColor: 'surface',
    textColor: 'text',
    playerColor: 'player',
    buttonColor: 'button',
  };

  const colors = {
    dark: { ...current.colors.dark, ...(patch.colors?.dark ?? {}) },
    light: { ...current.colors.light, ...(patch.colors?.light ?? {}) },
  };

  for (const [flat, role] of Object.entries(flatToDark)) {
    if (patch[flat] !== undefined) colors.dark[role] = patch[flat];
  }

  return {
    ...current,
    ...(patch.fontFamily !== undefined ? { fontFamily: patch.fontFamily } : {}),
    ...(patch.fontAssetId !== undefined ? { fontAssetId: patch.fontAssetId } : {}),
    ...(patch.appLogo !== undefined ? { appLogo: patch.appLogo } : {}),
    ...(patch.appIcon !== undefined ? { appIcon: patch.appIcon } : {}),
    typography: { ...current.typography, ...(patch.typography ?? {}) },
    colors,
    musicPlayer: { ...current.musicPlayer, ...(patch.musicPlayer ?? {}) },
  };
}

/** Restores the shipped identity, keeping the version monotonic. */
export async function resetTheme({ uid } = {}) {
  const current = normalise(await readTheme());
  const doc = {
    ...normalise(DEFAULT_THEME),
    version: current.version + 1,
    updatedAt: new Date(),
    updatedBy: uid ?? null,
  };
  await collections
    .appConfig()
    .updateOne({ _id: THEME_DOC_ID }, { $set: doc }, { upsert: true });
  return doc;
}
