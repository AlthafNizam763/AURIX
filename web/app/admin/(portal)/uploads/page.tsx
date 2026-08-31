import type { Metadata } from 'next';

import { requireAdmin } from '@/server/admin/session';
import { env } from '@/server/config/env';
import { normalise, readTheme } from '@/server/services/theme';
import { listFiles } from '@/server/services/uploads';
import { PageHeader } from '@components/ui';

import { UploadsManager } from './manager';

export const metadata: Metadata = { title: 'Uploads' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Uploaded files.
 *
 * Fonts only. Logos and icons are managed on the Appearance screen because they
 * are single-valued — there is one logo, and replacing it is the whole
 * interaction. Fonts are a collection an administrator curates.
 *
 * All of it lives in GridFS, which is the reason none of this needed rethinking
 * for serverless: the bytes are in MongoDB, which every instance reaches
 * equally. The one thing Vercel genuinely forbids — treating local disk as
 * storage — was never being done.
 */
export default async function UploadsPage() {
  await requireAdmin();

  const [fonts, theme] = await Promise.all([listFiles('font'), readTheme()]);
  const active = normalise(theme).fontFamily;

  return (
    <>
      <PageHeader
        eyebrow="Files"
        title="Uploads"
        description="Font files stored in GridFS and served from the API. The app downloads and caches them on the device."
      />

      <UploadsManager
        fonts={fonts.map((file) => ({
          id: file.id,
          url: file.url,
          family: file.filename.replace(/\.[^.]+$/, ''),
          contentType: file.contentType,
          length: file.length,
          uploadedAt: file.uploadedAt,
        }))}
        activeFamily={active}
        maxBytes={env.maxFontBytes}
      />
    </>
  );
}
