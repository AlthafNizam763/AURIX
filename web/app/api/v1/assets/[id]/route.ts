import type { Readable } from 'node:stream';

import { brandAssets } from '@/server/db/mongo';
import { handler } from '@/server/http/respond';
import { findFile, toObjectId } from '@/server/services/uploads';

/**
 * Serves an uploaded logo, icon or font file.
 *
 * Public: these are branding assets the app fetches before anyone has signed in,
 * for the same reason `GET /theme` is public.
 *
 * ## The headers are the security
 *
 * `Content-Type` is the type this API decided from the file's **magic bytes** on
 * upload, never the one the uploader claimed, and `X-Content-Type-Options:
 * nosniff` stops a browser overriding it. Anything unrecognised is served as
 * `application/octet-stream` with `Content-Disposition: attachment`, so a file
 * that somehow got past the upload check is downloaded rather than rendered.
 *
 * ## Caching
 *
 * `immutable` with a one-year max-age, which is safe because the id changes when
 * the file does — a new logo is a new GridFS document with a new URL, and the
 * theme is repointed at it. The ETag handles the case where a client asks
 * anyway.
 *
 * ## Streaming
 *
 * `stream.pipe(res)` became a `ReadableStream` in the response body. The bytes
 * are never fully buffered, which matters for a font on a serverless function
 * with a fixed memory ceiling.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = handler<{ id: string }>(async (request, { params }) => {
  const { id } = await params;

  const file = await findFile(id);
  const contentType = file.contentType ?? 'application/octet-stream';
  const etag = `"${file._id}"`;

  if (request.headers.get('if-none-match') === etag) {
    return new Response(null, { status: 304, headers: { ETag: etag } });
  }

  const bucket = await brandAssets();
  const nodeStream = bucket.openDownloadStream(toObjectId(id)) as unknown as Readable;

  // Node's Readable → the web ReadableStream a Response body wants.
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      nodeStream.on('data', (chunk: Buffer) => controller.enqueue(new Uint8Array(chunk)));
      nodeStream.on('end', () => controller.close());
      nodeStream.on('error', (error) => controller.error(error));
    },
    cancel() {
      nodeStream.destroy();
    },
  });

  return new Response(body, {
    headers: {
      'Content-Type': contentType,
      'Content-Length': String(file.length),
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      ETag: etag,
      ...(contentType === 'application/octet-stream'
        ? { 'Content-Disposition': 'attachment' }
        : {}),
    },
  });
});
