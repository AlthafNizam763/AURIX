import type { Metadata } from 'next';

import { requireAdmin } from '@/server/admin/session';
import {
  COLOR_KEYS,
  FONT_CATALOGUE,
  PLAYER_SURFACES,
  PLAYER_VARIANTS,
  normalise,
  readTheme,
} from '@/server/services/theme';
import { listFiles } from '@/server/services/uploads';
import { PageHeader } from '@components/ui';

import { AppearanceEditor } from './editor';

export const metadata: Metadata = { title: 'Appearance' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * The appearance editor.
 *
 * The only screen in the portal whose changes are visible to **every install**,
 * which is why the theme service normalises and bounds everything it stores and
 * why `version` is bumped on every write — the app renders from a cached copy on
 * launch and uses the version to decide whether that cache is stale.
 */
export default async function AppearancePage() {
  await requireAdmin();

  const theme = normalise(await readTheme());
  const uploadedFonts = await listFiles('font');

  const uploadedFamilies = new Set(
    uploadedFonts.map((file) => file.filename.replace(/\.[^.]+$/, '')),
  );

  const fonts = FONT_CATALOGUE.map((font) => ({
    family: font.family,
    note: font.note,
    // A family is usable when it ships inside the app *or* when a file has been
    // uploaded for it. Listing one with neither is not a broken state — the app
    // keeps its current face until a file arrives.
    available: font.bundled || uploadedFamilies.has(font.family),
    bundled: font.bundled,
  }));

  return (
    <>
      <PageHeader
        eyebrow="Identity"
        title="Appearance"
        description={`Currently on version ${theme.version}. Every save bumps it, which is how the app knows to refresh what it cached.`}
      />

      <AppearanceEditor
        theme={{
          version: theme.version,
          fontFamily: theme.fontFamily,
          colors: theme.colors,
          typography: { ...theme.typography },
          musicPlayer: theme.musicPlayer,
          appLogo: theme.appLogo,
          appIcon: theme.appIcon,
        }}
        colorKeys={[...COLOR_KEYS]}
        playerSurfaces={[...PLAYER_SURFACES]}
        playerVariants={[...PLAYER_VARIANTS]}
        fonts={fonts}
      />
    </>
  );
}
