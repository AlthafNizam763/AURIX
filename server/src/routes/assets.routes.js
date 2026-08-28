import express from 'express';

import { brandAssets } from '../db/mongo.js';
import { findFile, toObjectId } from '../services/uploads.js';
import { route } from '../utils/async.js';

/**
 * Serves uploaded branding assets out of GridFS.
 *
 * ## Public, and why that is right
 *
 * The logo is rendered on the splash and login screens, before any session
 * exists. An authenticated asset route would mean the app could not draw its
 * own branding until after sign-in.
 *
 * The ids are 12-byte ObjectIds and the only things in the bucket are logos,
 * icons and font files an administrator deliberately published to every user of
 * the app. Nothing here is private, so there is nothing for authentication to
 * protect.
 *
 * ## The two headers that matter
 *
 * `X-Content-Type-Options: nosniff` with a `Content-Type` this server decided
 * from the file's magic bytes — never from the uploader's header — is what stops
 * a crafted upload being interpreted as script. `Content-Disposition:
 * attachment` in the fallback case does the same job for anything whose type is
 * unknown.
 *
 * The long `max-age` is safe because these URLs are content-addressed in
 * practice: replacing the logo stores a new file and repoints the theme at a
 * new id, so a cached response is never stale — it simply stops being
 * referenced.
 */
const router = express.Router();

router.get(
  '/:id',
  route(async (req, res) => {
    const file = await findFile(req.params.id);
    const contentType = file.contentType ?? 'application/octet-stream';

    res.set({
      'Content-Type': contentType,
      'Content-Length': String(file.length),
      'Cache-Control': 'public, max-age=31536000, immutable',
      'X-Content-Type-Options': 'nosniff',
      ETag: `"${file._id}"`,
      ...(contentType === 'application/octet-stream'
        ? { 'Content-Disposition': 'attachment' }
        : {}),
    });

    if (req.get('if-none-match') === `"${file._id}"`) return res.status(304).end();

    const stream = brandAssets().openDownloadStream(toObjectId(req.params.id));

    // A stream error after headers are sent cannot become a JSON error
    // response — the status line is already on the wire. Destroy the socket
    // instead, which the client sees as a truncated body and retries, rather
    // than leaving the request hanging until it times out.
    stream.on('error', () => {
      if (!res.headersSent) res.status(500);
      res.destroy();
    });

    stream.pipe(res);
  }),
);

export default router;
