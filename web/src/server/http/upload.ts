import { env } from '../config/env';
import { badRequest, payloadTooLarge } from '../utils/errors';

/**
 * Reading an uploaded file out of a request.
 *
 * ## What this replaces
 *
 * `multer` with `memoryStorage` and a `limits.fileSize`. Next.js route handlers
 * have `request.formData()` built in, so the parser is gone; the *cap* is not,
 * and it has to be enforced here because there is no middleware left to do it.
 *
 * ## The cap is checked twice, deliberately
 *
 * Once against `Content-Length`, which lets an oversized upload be refused
 * before its bytes are read, and once against the actual buffer, because
 * `Content-Length` is supplied by the caller and a lying one would otherwise
 * walk straight past the first check.
 *
 * Note the platform limit sitting above both: Vercel refuses any request body
 * over 4.5MB before the function is invoked at all. `MAX_FONT_BYTES` is set
 * below that on purpose, so a too-large font fails as this API's
 * `payload_too_large` rather than as a platform error with no explanation.
 */

export interface UploadedFile {
  buffer: Buffer;
  filename: string;
  /** The type the *caller* claimed. Never trusted — see `services/uploads`. */
  declaredType: string;
}

export interface FormUpload {
  file: UploadedFile;
  /** The other form fields, e.g. the font family name. */
  fields: Record<string, string>;
}

/**
 * Reads the `file` part of a multipart body, enforcing [maxBytes].
 *
 * The returned `declaredType` is recorded for diagnostics only. What the file
 * actually *is* gets decided by its magic bytes in `requireKind`, because a
 * content type and a file extension are both things the caller chose.
 */
export async function readUpload(
  request: Request,
  { maxBytes, field = 'file' }: { maxBytes: number; field?: string },
): Promise<FormUpload> {
  // Cheap rejection first, before anything is buffered.
  const declaredLength = Number.parseInt(request.headers.get('content-length') ?? '', 10);
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw payloadTooLarge('That file is too large.');
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    throw badRequest('That upload was not a valid multipart form.');
  }

  const entry = form.get(field);
  if (!entry || typeof entry === 'string') throw badRequest('No file was uploaded.');

  const buffer = Buffer.from(await entry.arrayBuffer());
  // Again, against the bytes actually received: `Content-Length` is the
  // caller's claim, not a measurement.
  if (buffer.length > maxBytes) throw payloadTooLarge('That file is too large.');
  if (buffer.length === 0) throw badRequest('That file is empty.');

  const fields: Record<string, string> = {};
  for (const [key, value] of form.entries()) {
    if (key !== field && typeof value === 'string') fields[key] = value;
  }

  return {
    file: {
      buffer,
      filename: entry.name || field,
      declaredType: entry.type || 'application/octet-stream',
    },
    fields,
  };
}

/** The caps, read once so a route cannot invent its own. */
export const UPLOAD_LIMITS = {
  image: () => env.maxLogoBytes,
  font: () => env.maxFontBytes,
};
