'use server';

import { revalidatePath } from 'next/cache';

import { requireAdmin } from '@/server/admin/session';
import { UPLOAD_LIMITS } from '@/server/http/upload';
import {
  COLOR_KEYS,
  PLAYER_SURFACES,
  PLAYER_VARIANTS,
  resetTheme,
  writeTheme,
} from '@/server/services/theme';
import { pruneRole, requireKind, store } from '@/server/services/uploads';
import { ApiError } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/**
 * Editing the AURIX identity.
 *
 * Every action re-checks `requireAdmin()` — a Server Action is a POST endpoint
 * and does not re-run the layout above it.
 *
 * The theme is the one document that can make the app *unusable* rather than
 * merely different: a background and a text colour set to the same value paints
 * black on black for every install. The service normalises and bounds every
 * field it stores, and these actions do not bypass it.
 */

export interface ThemeState {
  error?: string;
  message?: string;
}

const HEX = /^#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/;

/** Turns a thrown ApiError into a message, and anything else into a generic one. */
function failure(error: unknown, fallback: string): ThemeState {
  if (error instanceof ApiError) return { error: error.message };
  log.error(fallback, 'admin', error);
  return { error: fallback };
}

export async function saveColours(
  _previous: ThemeState,
  formData: FormData,
): Promise<ThemeState> {
  const admin = await requireAdmin();

  const dark: Record<string, string> = {};
  const light: Record<string, string> = {};

  for (const key of COLOR_KEYS) {
    const darkValue = String(formData.get(`dark.${key}`) ?? '').trim();
    const lightValue = String(formData.get(`light.${key}`) ?? '').trim();
    // Refused rather than silently defaulted: an administrator who typed a
    // colour wrong should be told, not quietly given the old one back.
    if (darkValue && !HEX.test(darkValue)) return { error: `Dark ${key} is not a hex colour.` };
    if (lightValue && !HEX.test(lightValue)) return { error: `Light ${key} is not a hex colour.` };
    if (darkValue) dark[key] = darkValue;
    if (lightValue) light[key] = lightValue;
  }

  const musicPlayer: Record<string, string> = {};
  for (const surface of PLAYER_SURFACES) {
    const variant = String(formData.get(`player.${surface}`) ?? '');
    if ((PLAYER_VARIANTS as readonly string[]).includes(variant)) {
      musicPlayer[surface] = variant;
    }
  }

  const fontFamily = String(formData.get('fontFamily') ?? '').trim();

  try {
    const theme = await writeTheme(
      {
        colors: { dark, light },
        musicPlayer,
        ...(fontFamily ? { fontFamily } : {}),
      },
      { uid: admin.uid },
    );

    log.info(`Theme updated to version ${theme.version} by ${admin.uid}`, 'theme');
    revalidatePath('/admin/appearance');
    return { message: `Saved. The app is now on theme version ${theme.version}.` };
  } catch (error) {
    return failure(error, 'That change could not be saved.');
  }
}

export async function saveTypography(
  _previous: ThemeState,
  formData: FormData,
): Promise<ThemeState> {
  const admin = await requireAdmin();

  const number = (name: string): number | undefined => {
    const raw = String(formData.get(name) ?? '').trim();
    if (!raw) return undefined;
    const parsed = Number.parseFloat(raw);
    return Number.isFinite(parsed) ? parsed : undefined;
  };

  try {
    // The service clamps each of these to its documented range, so a value out
    // of bounds is corrected rather than stored — which is the behaviour the
    // API has too.
    const theme = await writeTheme(
      {
        typography: {
          scale: number('scale'),
          letterSpacing: number('letterSpacing'),
          weightRegular: number('weightRegular'),
          weightMedium: number('weightMedium'),
          weightBold: number('weightBold'),
          weightDisplay: number('weightDisplay'),
        },
      },
      { uid: admin.uid },
    );

    revalidatePath('/admin/appearance');
    return { message: `Saved. Theme version ${theme.version}.` };
  } catch (error) {
    return failure(error, 'That change could not be saved.');
  }
}

/**
 * Takes the previous state and an unused FormData so it matches the signature
 * `useActionState` gives a `<form action>` — a no-argument action cannot be
 * bound to a form directly.
 */
export async function restoreDefaults(
  _previous: ThemeState,
  _formData: FormData,
): Promise<ThemeState> {
  const admin = await requireAdmin();
  try {
    const theme = await resetTheme({ uid: admin.uid });
    log.info(`Theme reset to defaults by ${admin.uid}`, 'theme');
    revalidatePath('/admin/appearance');
    return { message: `Restored the AURIX identity. Theme version ${theme.version}.` };
  } catch (error) {
    return failure(error, 'The theme could not be reset.');
  }
}

/**
 * Replaces the logo or the icon.
 *
 * Store the new file, point the theme at it, *then* prune the old one. Pruning
 * first would leave a window in which the theme referenced a file that no longer
 * existed — and if the upload then failed, the logo would be gone for good.
 *
 * The type is decided by the file's **magic bytes**, never by its name or the
 * browser's `Content-Type`. SVG is refused: it is a document that can carry
 * script, and serving one from this origin is stored XSS against this portal.
 */
export async function uploadBrandImage(
  _previous: ThemeState,
  formData: FormData,
): Promise<ThemeState> {
  const admin = await requireAdmin();

  const role = String(formData.get('role') ?? '');
  if (role !== 'logo' && role !== 'icon') return { error: 'Unknown image role.' };

  const file = formData.get('file');
  if (!file || typeof file === 'string' || file.size === 0) {
    return { error: 'Choose a file first.' };
  }
  if (file.size > UPLOAD_LIMITS.image()) {
    return { error: 'That image is too large.' };
  }

  try {
    const buffer = Buffer.from(await file.arrayBuffer());
    const contentType = requireKind(buffer, 'image');

    const asset = await store(buffer, {
      filename: file.name || role,
      contentType,
      kind: 'image',
      role,
      uploadedBy: admin.uid,
    });

    await writeTheme(
      role === 'logo' ? { appLogo: asset.url } : { appIcon: asset.url },
      { uid: admin.uid },
    );
    await pruneRole(role, asset.id);

    log.info(`${role} replaced (${contentType}, ${asset.length} bytes)`, 'theme');
    revalidatePath('/admin/appearance');
    return { message: `New ${role} uploaded.` };
  } catch (error) {
    return failure(error, 'That file could not be uploaded.');
  }
}

export async function clearBrandImage(
  _previous: ThemeState,
  formData: FormData,
): Promise<ThemeState> {
  const admin = await requireAdmin();

  const role = String(formData.get('role') ?? '');
  if (role !== 'logo' && role !== 'icon') return { error: 'Unknown image role.' };

  try {
    await writeTheme(role === 'logo' ? { appLogo: null } : { appIcon: null }, {
      uid: admin.uid,
    });
    await pruneRole(role, null);
    revalidatePath('/admin/appearance');
    return { message: `The ${role} has been removed.` };
  } catch (error) {
    return failure(error, 'That image could not be removed.');
  }
}
