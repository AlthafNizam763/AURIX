import express from 'express';
import multer from 'multer';

import { env } from '../config/env.js';
import { optionalAuth, requireAdmin, requireAuth } from '../middleware/auth.js';
import { validate, z } from '../middleware/validate.js';
import {
  COLOR_KEYS,
  FONT_CATALOGUE,
  PLAYER_SURFACES,
  PLAYER_VARIANTS,
  readTheme,
  resetTheme,
  themeOut,
  writeTheme,
} from '../services/theme.js';
import {
  listFiles,
  pruneFamily,
  pruneRole,
  removeFile,
  requireKind,
  store,
} from '../services/uploads.js';
import { route } from '../utils/async.js';
import { badRequest } from '../utils/errors.js';
import { log } from '../utils/logger.js';

/**
 * Theme configuration — read by everyone, written by administrators.
 *
 * ## `GET /` is deliberately public
 *
 * The app fetches the theme before it has a session, because the login screen
 * has to be painted in the operator's colours and carry their logo. Requiring a
 * token here would mean every install showed the default identity until after
 * sign-in — the one screen where branding matters most would be the one screen
 * that never had it.
 *
 * Nothing in the document is sensitive: it is colours, a font name, a public
 * asset path and four player-variant names. `updatedBy` is the only field with
 * any identity in it, and it is dropped for anonymous callers below.
 */
const router = express.Router();

/**
 * Uploads are buffered in memory rather than spooled to disk.
 *
 * Correct here specifically because the size caps are small (2MB for a logo,
 * 4MB for a font) and the destination is GridFS — a disk round trip would only
 * add a temp file to clean up. The cap is enforced by multer *before* the
 * bytes are read, so an oversized upload is rejected at the socket rather than
 * after being buffered.
 */
const uploadImage = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: env.maxLogoBytes, files: 1 },
});

const uploadFont = multer({
  storage: multer.memoryStorage(),
  limits: { fileSize: env.maxFontBytes, files: 1 },
});

const hex = z
  .string()
  .trim()
  .regex(/^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, 'Colours must be #RRGGBB or #AARRGGBB.');

const palette = z.object(
  Object.fromEntries(COLOR_KEYS.map((key) => [key, hex.optional()])),
);

const themePatch = z
  .object({
    fontFamily: z.string().trim().min(1).max(64).optional(),
    fontAssetId: z.string().trim().max(64).nullish(),
    appLogo: z.string().trim().max(512).nullish(),
    appIcon: z.string().trim().max(512).nullish(),

    typography: z
      .object({
        scale: z.number().min(0.8).max(1.4).optional(),
        letterSpacing: z.number().min(-1).max(2).optional(),
        weightRegular: z.number().int().min(100).max(900).optional(),
        weightMedium: z.number().int().min(100).max(900).optional(),
        weightBold: z.number().int().min(100).max(900).optional(),
        weightDisplay: z.number().int().min(100).max(900).optional(),
      })
      .optional(),

    colors: z.object({ dark: palette.optional(), light: palette.optional() }).optional(),

    musicPlayer: z
      .object(
        Object.fromEntries(
          PLAYER_SURFACES.map((surface) => [surface, z.enum(PLAYER_VARIANTS).optional()]),
        ),
      )
      .optional(),

    // The flat spelling from the documented configuration format. Applies to
    // the dark colourway — see `mergePatch` in services/theme.js.
    primaryColor: hex.optional(),
    secondaryColor: hex.optional(),
    accentColor: hex.optional(),
    backgroundColor: hex.optional(),
    surfaceColor: hex.optional(),
    textColor: hex.optional(),
    playerColor: hex.optional(),
    buttonColor: hex.optional(),
  })
  .strip();

// ---------------------------------------------------------------------------
// Read
// ---------------------------------------------------------------------------

router.get(
  '/',
  optionalAuth,
  route(async (req, res) => {
    const theme = themeOut(await readTheme());

    // `updatedBy` is a uid. Harmless, but there is no reason for an
    // unauthenticated caller to learn one.
    if (!req.user) delete theme.updatedBy;

    // Cached briefly rather than not at all: the client already caches by
    // `version` on the device, and a short shared cache absorbs the thundering
    // herd of every install fetching this at the same moment after a release.
    res.set('Cache-Control', 'public, max-age=60');
    res.json({ theme });
  }),
);

/** Only the version, for a poll that wants to know whether to refetch. */
router.get(
  '/version',
  route(async (_req, res) => {
    const theme = await readTheme();
    res.json({ version: theme.version ?? 1, updatedAt: theme.updatedAt ?? null });
  }),
);

/** What the admin pickers offer. Static, but served so the app never hard-codes it. */
router.get(
  '/options',
  route(async (_req, res) => {
    const uploaded = await listFiles('font');
    const uploadedFamilies = new Map(
      uploaded.map((file) => [file.filename.replace(/\.[^.]+$/, ''), file]),
    );

    res.json({
      fonts: FONT_CATALOGUE.map((font) => {
        const file = uploadedFamilies.get(font.family);
        return {
          ...font,
          // A family is usable when it ships in the app or has a file here.
          // Anything else shows in the picker as needing an upload rather than
          // being hidden, so an admin can see the whole list and fix it.
          assetId: file?.id ?? null,
          url: file?.url ?? null,
          available: font.bundled || Boolean(file),
        };
      }),
      players: PLAYER_SURFACES.map((surface) => ({ surface, variants: PLAYER_VARIANTS })),
      colorRoles: COLOR_KEYS,
    });
  }),
);

// ---------------------------------------------------------------------------
// Write — administrators only
// ---------------------------------------------------------------------------

router.use(requireAuth, requireAdmin);

router.put(
  '/',
  validate({ body: themePatch }),
  route(async (req, res) => {
    if (Object.keys(req.body).length === 0) throw badRequest('Nothing to change.');
    const theme = await writeTheme(req.body, { uid: req.user.uid });
    log.info(`Theme updated to version ${theme.version} by ${req.user.uid}`, 'theme');
    res.json({ theme: themeOut(theme) });
  }),
);

router.post(
  '/reset',
  route(async (req, res) => {
    const theme = await resetTheme({ uid: req.user.uid });
    log.info(`Theme reset to defaults by ${req.user.uid}`, 'theme');
    res.json({ theme: themeOut(theme) });
  }),
);

/**
 * Replaces the app logo.
 *
 * The upload and the config change are one operation from the caller's point of
 * view, and the order matters: the file is stored first, then the theme points
 * at it, then the *previous* file is pruned. Pruning first would leave a window
 * where the stored `appLogo` names a file that no longer exists, which every
 * running client would render as a broken image.
 */
router.post(
  '/logo',
  uploadImage.single('file'),
  route(async (req, res) => {
    if (!req.file) throw badRequest('No file was uploaded.');

    const contentType = requireKind(req.file.buffer, 'image');
    const asset = await store(req.file.buffer, {
      filename: req.file.originalname || 'logo',
      contentType,
      kind: 'image',
      role: 'logo',
      uploadedBy: req.user.uid,
    });

    const theme = await writeTheme({ appLogo: asset.url }, { uid: req.user.uid });
    await pruneRole('logo', asset.id);

    log.info(`Logo replaced (${contentType}, ${asset.length} bytes)`, 'theme');
    res.status(201).json({ asset, theme: themeOut(theme) });
  }),
);

/** Returns to the drawn AURIX mark. The bundled fallback is never deleted. */
router.delete(
  '/logo',
  route(async (req, res) => {
    const theme = await writeTheme({ appLogo: null }, { uid: req.user.uid });
    await pruneRole('logo', null);
    res.json({ theme: themeOut(theme) });
  }),
);

router.post(
  '/icon',
  uploadImage.single('file'),
  route(async (req, res) => {
    if (!req.file) throw badRequest('No file was uploaded.');

    const contentType = requireKind(req.file.buffer, 'image');
    const asset = await store(req.file.buffer, {
      filename: req.file.originalname || 'icon',
      contentType,
      kind: 'image',
      role: 'icon',
      uploadedBy: req.user.uid,
    });

    const theme = await writeTheme({ appIcon: asset.url }, { uid: req.user.uid });
    await pruneRole('icon', asset.id);
    res.status(201).json({ asset, theme: themeOut(theme) });
  }),
);

router.delete(
  '/icon',
  route(async (req, res) => {
    const theme = await writeTheme({ appIcon: null }, { uid: req.user.uid });
    await pruneRole('icon', null);
    res.json({ theme: themeOut(theme) });
  }),
);

/**
 * Uploads a font file for a family.
 *
 * The file is stored under the family name so `GET /options` can pair the two,
 * and the theme is only repointed when `apply=true` — an admin uploading
 * Poppins and Inter before deciding between them should not repaint the app
 * twice on the way.
 *
 * The bytes are checked against the font magic numbers, which is what stops
 * "upload a font" from being a route that serves arbitrary content from the API
 * origin.
 */
router.post(
  '/fonts',
  uploadFont.single('file'),
  route(async (req, res) => {
    if (!req.file) throw badRequest('No file was uploaded.');

    const family = String(req.body?.family ?? '').trim();
    if (!family || family.length > 64) throw badRequest('Name the font family.');

    const contentType = requireKind(req.file.buffer, 'font');
    const asset = await store(req.file.buffer, {
      // The family is the filename, because that pairing is what
      // `GET /options` and the client's `FontRegistry` both look it up by.
      filename: family,
      contentType,
      kind: 'font',
      role: 'font',
      uploadedBy: req.user.uid,
    });

    // Only earlier uploads of *this* family. An admin who keeps Poppins and
    // Inter both uploaded so they can switch between them must not lose one by
    // re-uploading the other.
    await pruneFamily(family, asset.id).catch(() => {});

    const apply = String(req.body?.apply ?? '') === 'true';
    const theme = apply
      ? await writeTheme({ fontFamily: family, fontAssetId: asset.id }, { uid: req.user.uid })
      : await readTheme();

    log.info(`Font "${family}" uploaded (${contentType}, ${asset.length} bytes)`, 'theme');
    res.status(201).json({ asset, family, theme: themeOut(theme) });
  }),
);

router.get(
  '/fonts',
  route(async (_req, res) => {
    res.json({ fonts: await listFiles('font') });
  }),
);

router.delete(
  '/fonts/:id',
  route(async (req, res) => {
    await removeFile(req.params.id);
    res.status(204).end();
  }),
);

export default router;
