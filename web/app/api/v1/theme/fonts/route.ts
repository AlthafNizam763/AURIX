import { created, ok } from '@/server/http/respond';
import { UPLOAD_LIMITS, readUpload } from '@/server/http/upload';
import { withAdmin } from '@/server/middleware/auth';
import { readTheme, themeOut, writeTheme } from '@/server/services/theme';
import { listFiles, pruneFamily, requireKind, store } from '@/server/services/uploads';
import { badRequest } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/**
 * Uploaded font files.
 *
 * ## Why fonts prune by family rather than by role
 *
 * There is one logo, but an admin legitimately keeps several families uploaded
 * and switches between them. Pruning by role — as the logo does — would delete
 * Inter the moment Poppins was uploaded.
 *
 * ## `apply` is opt-in
 *
 * Uploading a face and *using* it are separate decisions: an admin may want the
 * file present before switching the whole app onto it.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withAdmin(async () => ok({ fonts: await listFiles('font') }));

export const POST = withAdmin(async (request, { auth }) => {
  const { file, fields } = await readUpload(request, { maxBytes: UPLOAD_LIMITS.font() });

  const family = String(fields.family ?? '').trim();
  if (!family || family.length > 64) throw badRequest('Name the font family.');

  const contentType = requireKind(file.buffer, 'font');

  const asset = await store(file.buffer, {
    // The family is the filename, which is what `pruneFamily` and the options
    // endpoint match on.
    filename: family,
    contentType,
    kind: 'font',
    role: 'font',
    uploadedBy: auth.uid,
  });

  await pruneFamily(family, asset.id).catch(() => undefined);

  const theme =
    fields.apply === 'true'
      ? await writeTheme({ fontFamily: family, fontAssetId: asset.id }, { uid: auth.uid })
      : await readTheme();

  log.info(`Font "${family}" uploaded (${contentType}, ${asset.length} bytes)`, 'theme');
  return created({ asset, family, theme: themeOut(theme) });
});
