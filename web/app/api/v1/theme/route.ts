import { ok } from '@/server/http/respond';
import { body, z } from '@/server/http/validate';
import { withAdmin, withOptionalAuth } from '@/server/middleware/auth';
import {
  COLOR_KEYS,
  PLAYER_SURFACES,
  PLAYER_VARIANTS,
  readTheme,
  themeOut,
  writeTheme,
} from '@/server/services/theme';
import { badRequest } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/** The application theme: read by everyone, written by administrators. */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Public, and read before anyone has signed in.
 *
 * The login screen has to be drawn first, so refusing this to an anonymous
 * caller would leave it unstyled. `updatedBy` is stripped for anonymous callers
 * — the palette is public, the identity of the administrator who set it is not.
 */
export const GET = withOptionalAuth(async (_request, { auth }) => {
  const theme = themeOut(await readTheme());
  if (!auth) delete theme.updatedBy;

  return Response.json(
    { theme },
    { headers: { 'Cache-Control': 'public, max-age=60' } },
  );
});

const hex = z
  .string()
  .trim()
  .regex(/^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/, 'Colours must be #RRGGBB or #AARRGGBB.');

const palette = z.object(
  Object.fromEntries(COLOR_KEYS.map((key) => [key, hex.optional()])),
);

/**
 * Accepts both shapes — nested `colors.dark.primary` and flat `primaryColor`.
 *
 * The portal sends the first; the documented configuration format uses the
 * second. `.strip()` drops anything else rather than storing it.
 */
const themePatch = z
  .object({
    fontFamily: z.string().trim().min(1).max(64).optional(),
    fontAssetId: z.string().trim().max(64).nullish(),
    appLogo: z.string().trim().max(512).nullish(),
    appIcon: z.string().trim().max(512).nullish(),
    typography: z
      .object({
        // Bounded, because these are the numbers that can make the app
        // unreadable rather than merely ugly.
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

export const PUT = withAdmin(async (request, { auth }) => {
  const patch = await body(request, themePatch);
  if (Object.keys(patch).length === 0) throw badRequest('Nothing to change.');

  const theme = await writeTheme(patch, { uid: auth.uid });
  log.info(`Theme updated to version ${theme.version} by ${auth.uid}`, 'theme');

  return ok({ theme: themeOut(theme) });
});
