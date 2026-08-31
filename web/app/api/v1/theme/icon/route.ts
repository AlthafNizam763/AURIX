import { created, ok } from '@/server/http/respond';
import { UPLOAD_LIMITS, readUpload } from '@/server/http/upload';
import { withAdmin } from '@/server/middleware/auth';
import { themeOut, writeTheme } from '@/server/services/theme';
import { pruneRole, requireKind, store } from '@/server/services/uploads';
import { log } from '@/server/utils/logger';

/**
 * The application icon.
 *
 * Identical handling to the logo — same magic-byte check, same store-then-point-
 * then-prune ordering, same SVG refusal. They are separate roles rather than one
 * because an admin sets them independently and each keeps exactly one file.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const POST = withAdmin(async (request, { auth }) => {
  const { file } = await readUpload(request, { maxBytes: UPLOAD_LIMITS.image() });

  const contentType = requireKind(file.buffer, 'image');

  const asset = await store(file.buffer, {
    filename: file.filename || 'icon',
    contentType,
    kind: 'image',
    role: 'icon',
    uploadedBy: auth.uid,
  });

  const theme = await writeTheme({ appIcon: asset.url }, { uid: auth.uid });
  await pruneRole('icon', asset.id);

  log.info(`Icon replaced (${contentType}, ${asset.length} bytes)`, 'theme');
  return created({ asset, theme: themeOut(theme) });
});

export const DELETE = withAdmin(async (_request, { auth }) => {
  const theme = await writeTheme({ appIcon: null }, { uid: auth.uid });
  await pruneRole('icon', null);
  return ok({ theme: themeOut(theme) });
});
