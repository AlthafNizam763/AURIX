import { created, ok } from '@/server/http/respond';
import { UPLOAD_LIMITS, readUpload } from '@/server/http/upload';
import { withAdmin } from '@/server/middleware/auth';
import { themeOut, writeTheme } from '@/server/services/theme';
import { pruneRole, requireKind, store } from '@/server/services/uploads';
import { log } from '@/server/utils/logger';

/**
 * The application logo.
 *
 * ## The order of operations is the safety
 *
 * Store the new file, point the theme at it, *then* delete the old one. Pruning
 * first would leave a window in which the theme referenced a file that no longer
 * existed — and if the upload then failed, the logo would be gone for good.
 *
 * ## SVG is refused, and that is not an oversight
 *
 * `requireKind` decides the type from the file's magic bytes, and the image
 * signatures deliberately exclude SVG. An SVG is a document that can carry
 * script, and serving one from the API origin is stored XSS against the admin
 * portal that a raster format simply does not have.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const POST = withAdmin(async (request, { auth }) => {
  const { file } = await readUpload(request, { maxBytes: UPLOAD_LIMITS.image() });

  const contentType = requireKind(file.buffer, 'image');

  const asset = await store(file.buffer, {
    filename: file.filename || 'logo',
    contentType,
    kind: 'image',
    role: 'logo',
    uploadedBy: auth.uid,
  });

  const theme = await writeTheme({ appLogo: asset.url }, { uid: auth.uid });
  await pruneRole('logo', asset.id);

  log.info(`Logo replaced (${contentType}, ${asset.length} bytes)`, 'theme');
  return created({ asset, theme: themeOut(theme) });
});

export const DELETE = withAdmin(async (_request, { auth }) => {
  const theme = await writeTheme({ appLogo: null }, { uid: auth.uid });
  await pruneRole('logo', null);
  return ok({ theme: themeOut(theme) });
});
