import { ObjectId, type Document, type Filter } from 'mongodb';

import { GRIDFS_BUCKET } from '../db/collections';
import { brandAssets, getDb } from '../db/mongo';
import { badRequest, notFound, unsupportedMedia } from '../utils/errors';

/**
 * Uploaded branding assets — logos, app icons and font files — in GridFS.
 *
 * ## Why the file type is decided by its bytes, never by its name
 *
 * A `Content-Type` header and a `.png` extension are both supplied by the
 * caller, and an admin portal is exactly the surface where "upload an image"
 * turns into "serve arbitrary content from our origin". So every upload is
 * identified by its magic bytes here, the stored `contentType` is the one this
 * function decided, and the serving route sends that stored value with
 * `X-Content-Type-Options: nosniff`.
 *
 * **SVG is deliberately not accepted** for logos. An SVG is a document that can
 * carry script, and serving one from the API origin is a stored-XSS vector
 * against the admin portal that a raster format simply does not have. The cost
 * is that a logo has to be uploaded as a PNG or WebP, which is what the app
 * renders anyway.
 *
 * ## Why GridFS survived the move to serverless
 *
 * Because it was never the filesystem. The bytes live in MongoDB, which every
 * instance reaches equally — so the one thing Vercel genuinely forbids, treating
 * local disk as storage, was never being done. Uploads are capped well under
 * Vercel's 4.5MB request limit; reads stream.
 */

const IMAGE_SIGNATURES = [
  { type: 'image/png', bytes: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a] },
  { type: 'image/jpeg', bytes: [0xff, 0xd8, 0xff] },
  { type: 'image/gif', bytes: [0x47, 0x49, 0x46, 0x38] },
];

const FONT_SIGNATURES = [
  // TrueType. `\0\1\0\0` is the version tag, not text.
  { type: 'font/ttf', bytes: [0x00, 0x01, 0x00, 0x00] },
  { type: 'font/ttf', bytes: [0x74, 0x72, 0x75, 0x65] }, // 'true'
  { type: 'font/otf', bytes: [0x4f, 0x54, 0x54, 0x4f] }, // 'OTTO'
  { type: 'font/woff', bytes: [0x77, 0x4f, 0x46, 0x46] }, // 'wOFF'
  { type: 'font/woff2', bytes: [0x77, 0x4f, 0x46, 0x32] }, // 'wOF2'
  { type: 'font/collection', bytes: [0x74, 0x74, 0x63, 0x66] }, // 'ttcf'
];

function startsWith(buffer: Buffer, bytes: number[]): boolean {
  if (buffer.length < bytes.length) return false;
  return bytes.every((byte, index) => buffer[index] === byte);
}

/** WebP is `RIFF....WEBP` — a container tag at offset 8, not a prefix. */
function isWebp(buffer: Buffer): boolean {
  return (
    buffer.length >= 12 &&
    startsWith(buffer, [0x52, 0x49, 0x46, 0x46]) &&
    buffer.subarray(8, 12).toString('ascii') === 'WEBP'
  );
}

export function detectImage(buffer: Buffer): string | null {
  if (isWebp(buffer)) return 'image/webp';
  for (const signature of IMAGE_SIGNATURES) {
    if (startsWith(buffer, signature.bytes)) return signature.type;
  }
  return null;
}

export function detectFont(buffer: Buffer): string | null {
  for (const signature of FONT_SIGNATURES) {
    if (startsWith(buffer, signature.bytes)) return signature.type;
  }
  return null;
}

/** Rejects an upload whose bytes are not the kind the route asked for. */
export function requireKind(buffer: Buffer, kind: 'image' | 'font'): string {
  const detected = kind === 'font' ? detectFont(buffer) : detectImage(buffer);
  if (!detected) {
    throw unsupportedMedia(
      kind === 'font'
        ? 'That file is not a TTF, OTF, WOFF or WOFF2 font.'
        : 'That file is not a PNG, JPEG, WebP or GIF image.',
    );
  }
  return detected;
}

export interface StoredAsset {
  id: string;
  url: string;
  contentType: string;
  length: number;
}

/**
 * Stores a validated file and returns its id and public path.
 *
 * `kind` and `role` travel in the metadata so the portal can list what has been
 * uploaded, and so [pruneRole] can find and delete the file a new upload
 * supersedes — an admin who changes the logo six times should leave one file
 * behind, not six.
 */
export async function store(
  buffer: Buffer,
  {
    filename,
    contentType,
    kind,
    role,
    uploadedBy,
  }: {
    filename: string;
    contentType: string;
    kind: string;
    role: string;
    uploadedBy: string;
  },
): Promise<StoredAsset> {
  const bucket = await brandAssets();

  return new Promise<StoredAsset>((resolve, reject) => {
    const stream = bucket.openUploadStream(filename, {
      contentType,
      metadata: { kind, role, uploadedBy, uploadedAt: new Date() },
    });
    stream.on('error', reject);
    stream.on('finish', () =>
      resolve({
        id: String(stream.id),
        url: `/api/v1/assets/${stream.id}`,
        contentType,
        length: buffer.length,
      }),
    );
    stream.end(buffer);
  });
}

/**
 * Deletes every file matching `filter` except `keepId`.
 *
 * Called after an upload has been stored *and* pointed at, never before. A file
 * already gone is the desired end state, so a failed delete is swallowed rather
 * than failing the upload that caused it.
 */
export async function prune(filter: Filter<Document>, keepId: string | null): Promise<void> {
  const db = await getDb();
  const files = await db
    .collection(`${GRIDFS_BUCKET}.files`)
    .find(filter, { projection: { _id: 1 } })
    .toArray();

  const bucket = await brandAssets();
  for (const file of files) {
    if (String(file._id) === String(keepId)) continue;
    try {
      await bucket.delete(file._id as ObjectId);
    } catch {
      // Already gone.
    }
  }
}

/** Every earlier file for a role — the logo and icon, which have one each. */
export const pruneRole = (role: string, keepId: string | null) =>
  prune({ 'metadata.role': role }, keepId);

/**
 * Earlier uploads of one font *family*, leaving other families alone.
 *
 * Fonts differ from the logo: there is one logo, but an admin legitimately keeps
 * several families uploaded and switches between them. Pruning by role alone
 * would delete Inter the moment Poppins was uploaded.
 */
export const pruneFamily = (family: string, keepId: string | null) =>
  prune({ 'metadata.role': 'font', filename: family }, keepId);

export function toObjectId(value: string): ObjectId {
  if (!ObjectId.isValid(value)) throw badRequest('That is not a valid asset id.');
  return new ObjectId(value);
}

export async function findFile(id: string): Promise<Document> {
  const db = await getDb();
  const file = await db
    .collection(`${GRIDFS_BUCKET}.files`)
    .findOne({ _id: toObjectId(id) });
  if (!file) throw notFound('No such asset.');
  return file;
}

export interface AssetSummary {
  id: string;
  url: string;
  filename: string;
  contentType: string;
  length: number;
  uploadedAt: string | null;
  kind: string | null;
  role: string | null;
}

export async function listFiles(role?: string): Promise<AssetSummary[]> {
  const db = await getDb();
  const filter = role ? { 'metadata.role': role } : {};
  const files = await db
    .collection(`${GRIDFS_BUCKET}.files`)
    .find(filter)
    .sort({ uploadDate: -1 })
    .limit(100)
    .toArray();

  return files.map((file) => ({
    id: String(file._id),
    url: `/api/v1/assets/${file._id}`,
    filename: file.filename,
    contentType: file.contentType ?? 'application/octet-stream',
    length: file.length,
    uploadedAt: file.uploadDate?.toISOString() ?? null,
    kind: file.metadata?.kind ?? null,
    role: file.metadata?.role ?? null,
  }));
}

export async function removeFile(id: string): Promise<void> {
  try {
    const bucket = await brandAssets();
    await bucket.delete(toObjectId(id));
  } catch (error) {
    if (String((error as Error)?.message ?? '').includes('File not found')) {
      throw notFound('No such asset.');
    }
    throw error;
  }
}
