import { ApiError } from '../utils/errors.js';
import { log } from '../utils/logger.js';
import { env } from '../config/env.js';

/** 404 for anything no router claimed. */
export function notFoundHandler(req, res) {
  res.status(404).json({
    error: { code: 'not_found', message: `No route for ${req.method} ${req.path}` },
  });
}

/**
 * The single place a failure becomes a response.
 *
 * Two categories, treated very differently:
 *
 *  * **[ApiError]** — a failure the API meant to produce. Its code and message
 *    were written to be shown to a user, so both go out as-is.
 *  * **Everything else** — a bug, a driver error, a malformed body Express
 *    rejected. The client gets `internal` and a generic sentence; the real
 *    message goes to the log. This is not politeness: a `MongoServerError`
 *    quotes the failing filter, which can contain another user's uid, and an
 *    unhandled `SyntaxError` from the body parser quotes the payload.
 */
// eslint-disable-next-line no-unused-vars -- Express identifies error middleware by arity.
export function errorHandler(error, req, res, _next) {
  if (error instanceof ApiError) {
    if (error.status >= 500) log.error(`${req.method} ${req.path} — ${error.message}`, 'http', error);
    return res.status(error.status).json(error.toJSON());
  }

  // Body-parser and multer failures arrive with their own status/code.
  if (error?.type === 'entity.too.large' || error?.code === 'LIMIT_FILE_SIZE') {
    return res.status(413).json({
      error: { code: 'payload_too_large', message: 'That file is too large.' },
    });
  }
  if (error?.type === 'entity.parse.failed') {
    return res.status(400).json({
      error: { code: 'bad_request', message: 'That request body was not valid JSON.' },
    });
  }
  // A duplicate key means a unique index did its job — almost always a
  // concurrent create of a row that is meant to be unique. Surfacing it as a
  // conflict lets the client decide, rather than reading as a server fault.
  if (error?.code === 11000) {
    return res.status(409).json({
      error: { code: 'conflict', message: 'That already exists.' },
    });
  }

  log.error(`Unhandled error on ${req.method} ${req.path}`, 'http', error);
  return res.status(500).json({
    error: {
      code: 'internal',
      message: 'Something went wrong on our side.',
      ...(env.isProduction ? {} : { debug: String(error?.message ?? error) }),
    },
  });
}
