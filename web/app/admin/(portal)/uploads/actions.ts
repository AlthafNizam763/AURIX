'use server';

import { revalidatePath } from 'next/cache';

import { requireAdmin } from '@/server/admin/session';
import { UPLOAD_LIMITS } from '@/server/http/upload';
import { writeTheme } from '@/server/services/theme';
import { pruneFamily, removeFile, requireKind, store } from '@/server/services/uploads';
import { ApiError } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/** Managing uploaded font files. */

export interface UploadState {
  error?: string;
  message?: string;
}

function failure(error: unknown, fallback: string): UploadState {
  if (error instanceof ApiError) return { error: error.message };
  log.error(fallback, 'admin', error);
  return { error: fallback };
}

/**
 * Adds a font file.
 *
 * ## Why fonts prune by family rather than by role
 *
 * There is one logo, but an administrator legitimately keeps several families
 * uploaded and switches between them. Pruning by role — as the logo does — would
 * delete Inter the moment Poppins was uploaded. So the family name is the
 * filename, and only earlier files of the *same* family are removed.
 *
 * `apply` is separate from the upload because having a face available and
 * switching the whole app onto it are different decisions.
 */
export async function uploadFont(
  _previous: UploadState,
  formData: FormData,
): Promise<UploadState> {
  const admin = await requireAdmin();

  const family = String(formData.get('family') ?? '').trim();
  if (!family) return { error: 'Name the font family.' };
  if (family.length > 64) return { error: 'That family name is too long.' };

  const file = formData.get('file');
  if (!file || typeof file === 'string' || file.size === 0) {
    return { error: 'Choose a font file first.' };
  }
  if (file.size > UPLOAD_LIMITS.font()) {
    // The cap sits below Vercel's 4.5MB request limit on purpose, so an
    // oversized font fails here with an explanation rather than as a platform
    // error with none.
    return { error: 'That font is too large.' };
  }

  try {
    const buffer = Buffer.from(await file.arrayBuffer());
    // Decided by the file's magic bytes, never by its extension.
    const contentType = requireKind(buffer, 'font');

    const asset = await store(buffer, {
      filename: family,
      contentType,
      kind: 'font',
      role: 'font',
      uploadedBy: admin.uid,
    });

    await pruneFamily(family, asset.id).catch(() => undefined);

    if (String(formData.get('apply') ?? '') === 'on') {
      await writeTheme({ fontFamily: family, fontAssetId: asset.id }, { uid: admin.uid });
    }

    log.info(`Font "${family}" uploaded (${contentType}, ${asset.length} bytes)`, 'theme');
    revalidatePath('/admin/uploads');
    revalidatePath('/admin/appearance');
    return { message: `“${family}” uploaded.` };
  } catch (error) {
    return failure(error, 'That font could not be uploaded.');
  }
}

export async function deleteFont(
  _previous: UploadState,
  formData: FormData,
): Promise<UploadState> {
  await requireAdmin();

  const id = String(formData.get('id') ?? '');
  if (!id) return { error: 'No file was named.' };

  try {
    await removeFile(id);
    revalidatePath('/admin/uploads');
    revalidatePath('/admin/appearance');
    return { message: 'That file has been deleted.' };
  } catch (error) {
    return failure(error, 'That file could not be deleted.');
  }
}
