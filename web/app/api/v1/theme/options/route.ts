import { handler, ok } from '@/server/http/respond';
import {
  COLOR_KEYS,
  FONT_CATALOGUE,
  PLAYER_SURFACES,
  PLAYER_VARIANTS,
} from '@/server/services/theme';
import { listFiles } from '@/server/services/uploads';

/**
 * What the appearance editor may offer.
 *
 * Fonts are the interesting part: a family is `available` when it ships inside
 * the app *or* when a file has been uploaded for it. Listing a family with no
 * file is not a broken state — the picker marks it as needing an upload, and the
 * app keeps its current face until one arrives.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = handler(async () => {
  const uploaded = await listFiles('font');

  // Uploaded fonts are stored under the family name as their filename, so the
  // extension is stripped to match the catalogue entry.
  const uploadedFamilies = new Map(
    uploaded.map((file) => [file.filename.replace(/\.[^.]+$/, ''), file]),
  );

  return ok({
    fonts: FONT_CATALOGUE.map((font) => {
      const file = uploadedFamilies.get(font.family);
      return {
        ...font,
        assetId: file?.id ?? null,
        url: file?.url ?? null,
        available: font.bundled || Boolean(file),
      };
    }),
    players: PLAYER_SURFACES.map((surface) => ({ surface, variants: PLAYER_VARIANTS })),
    colorRoles: COLOR_KEYS,
  });
});
