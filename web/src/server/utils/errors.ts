/**
 * The API's error vocabulary. Ported from `server/src/utils/errors.js`.
 *
 * Every failure the client is expected to *handle* — as opposed to merely
 * report — gets a stable machine-readable `code`, because the Dart side
 * branches on it. `AuthFailure.kind` in `api_auth_service.dart` is a switch over
 * exactly these strings, so **renaming one here silently degrades a specific
 * sign-in error message into a generic one on the client.** The strings are a
 * published interface; treat them as one.
 *
 * Anything not raised through [ApiError] becomes a 500 with the code `internal`,
 * and its message is replaced before it reaches the client — an unexpected
 * `MongoServerError` must never hand its text, which can quote a query and a
 * collection name, to a caller.
 */

export type ErrorCode =
  | 'bad_request'
  | 'invalid_credentials'
  | 'unauthenticated'
  | 'token_expired'
  | 'forbidden'
  | 'admin_only'
  | 'not_found'
  | 'conflict'
  | 'email_in_use'
  | 'weak_password'
  | 'invalid_email'
  | 'invalid_phone'
  | 'phone_in_use'
  | 'identity_in_use'
  | 'invalid_code'
  | 'code_expired'
  | 'last_sign_in_method'
  | 'otp_unavailable'
  | 'provider_unavailable'
  | 'invalid_auth_state'
  | 'rate_limited'
  | 'payload_too_large'
  | 'unsupported_media_type'
  | 'unavailable'
  | 'internal';

export interface ErrorDetail {
  path: string;
  message: string;
}

export interface ErrorBody {
  error: {
    code: ErrorCode;
    message: string;
    details?: ErrorDetail[];
  };
}

export class ApiError extends Error {
  readonly status: number;
  readonly code: ErrorCode;
  readonly details?: ErrorDetail[];

  /**
   * Response headers this failure carries.
   *
   * Only the rate limiter sets these, to attach `Retry-After` and the
   * `RateLimit-*` family to a 429. Kept on the error rather than plumbed
   * through every handler because the throw is what knows the numbers, and the
   * alternative — returning them alongside every result so a wrapper can find
   * them — would put rate-limiting concerns in the signature of routes that
   * have nothing to do with it.
   */
  headers?: Record<string, string>;

  constructor(status: number, code: ErrorCode, message: string, details?: ErrorDetail[]) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.details = details;
  }

  toJSON(): ErrorBody {
    return {
      error: {
        code: this.code,
        message: this.message,
        ...(this.details ? { details: this.details } : {}),
      },
    };
  }
}

export const badRequest = (message: string, details?: ErrorDetail[]) =>
  new ApiError(400, 'bad_request', message, details);

export const invalidCredentials = () =>
  new ApiError(401, 'invalid_credentials', 'That email and password do not match.');

export const unauthorized = (message = 'Sign in to continue.') =>
  new ApiError(401, 'unauthenticated', message);

export const tokenExpired = () =>
  new ApiError(401, 'token_expired', 'Your session has expired. Sign in again.');

export const forbidden = (message = 'You do not have access to that.') =>
  new ApiError(403, 'forbidden', message);

export const adminOnly = () =>
  new ApiError(403, 'admin_only', 'That change can only be made by an administrator.');

export const notFound = (message = 'Not found.') => new ApiError(404, 'not_found', message);

export const conflict = (code: ErrorCode, message: string) => new ApiError(409, code, message);

export const emailInUse = () =>
  conflict('email_in_use', 'An account already exists for that email address.');

export const weakPassword = () =>
  new ApiError(400, 'weak_password', 'Use at least 8 characters.');

export const invalidEmail = () =>
  new ApiError(400, 'invalid_email', 'That does not look like an email address.');

// ---------------------------------------------------------------------------
// Multi-method sign-in
// ---------------------------------------------------------------------------

export const invalidPhone = () =>
  new ApiError(
    400,
    'invalid_phone',
    'That does not look like a phone number. Include the country code, for example +44 7700 900123.',
  );

export const phoneInUse = () =>
  conflict('phone_in_use', 'That number is already on another AURIX account.');

/**
 * The provider account is attached to a *different* AURIX user.
 *
 * Distinct from [emailInUse] on purpose: this is not "someone registered with
 * your address", it is "this exact Google/Apple/GitHub account is already a way
 * into another account", and the only remedy is to unlink it there. Merging the
 * two errors would send the user to a password reset that cannot help them.
 */
export const identityInUse = (provider: string) =>
  conflict(
    'identity_in_use',
    `That ${provider} account is already linked to a different AURIX account.`,
  );

export const invalidCode = () => new ApiError(401, 'invalid_code', 'That code is not correct.');

export const codeExpired = () =>
  new ApiError(401, 'code_expired', 'That code has expired. Ask for a new one.');

/**
 * Refuses to remove the only way back in.
 *
 * Unlinking is the one account operation that can lock its owner out
 * irreversibly — an account whose last identity is gone has no sign-in path and
 * no reset path either, because a reset needs an address to send to.
 */
export const lastSignInMethod = () =>
  conflict(
    'last_sign_in_method',
    'That is the only way into this account. Add a password or another ' +
      'sign-in method before removing it.',
  );

/**
 * Phone sign-in is switched off because nothing can deliver a code.
 *
 * Its own code rather than a generic 503, because the client turns it into a
 * sentence that tells the user to use another method — and because the fix is
 * an operator's, not theirs.
 */
export const otpUnavailable = () =>
  new ApiError(
    503,
    'otp_unavailable',
    'Signing in by phone is not available on this AURIX server.',
  );

/** The deployment has no credentials for the provider that was asked for. */
export const providerUnavailable = (provider: string) =>
  new ApiError(
    503,
    'provider_unavailable',
    `Signing in with ${provider} is not available on this AURIX server.`,
  );

/** A browser flow that came back wrong — a stale, forged or replayed callback. */
export const invalidAuthState = () =>
  new ApiError(
    400,
    'invalid_auth_state',
    'That sign-in attempt is no longer valid. Start again.',
  );

export const tooManyRequests = (message = 'Too many attempts. Try again shortly.') =>
  new ApiError(429, 'rate_limited', message);

export const payloadTooLarge = (message: string) =>
  new ApiError(413, 'payload_too_large', message);

export const unsupportedMedia = (message: string) =>
  new ApiError(415, 'unsupported_media_type', message);

export const unavailable = (message = 'The service is temporarily unavailable.') =>
  new ApiError(503, 'unavailable', message);
