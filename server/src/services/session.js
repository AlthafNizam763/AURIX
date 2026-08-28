import { issueAccessToken, issueRefreshToken } from './tokens.js';
import { accountView } from './users.js';

/**
 * The one shape a successful authentication has, whichever door it came in by.
 *
 * ## Why this is a module and not four copies of five lines
 *
 * AURIX now has six ways to become signed in — a password, a phone code, and
 * four social providers — plus a refresh and an account link that also mint
 * sessions. The client has exactly one piece of code that reads the result,
 * and it is `ApiAuthService._authenticate`: it expects `user`, `accessToken`,
 * `refreshToken` and `expiresAt`, stores them, and emits a session change.
 *
 * That only holds while every path produces the identical payload. A route
 * that assembled its own — omitting `expiresAt`, say, or returning
 * `publicUser` where every other path returns an [accountView] with the linked
 * providers filled in — would work in isolation and quietly produce an account
 * that appears to have no Google linked the moment you signed in with Google.
 *
 * So: no route builds a session. They all call this.
 *
 * ## What is deliberately *not* here
 *
 * Any hint of how the user authenticated. The token carries a uid, an email
 * and an admin flag, and nothing about whether a password or an Apple ID was
 * involved — because nothing downstream should behave differently. A playlist
 * write does not care, and a route that did care would be a route that treats
 * some accounts as second class.
 */
export async function buildSession(user, { device, ...extra } = {}) {
  const refresh = await issueRefreshToken(user.uid, { device });
  return {
    user: await accountView(user),
    accessToken: issueAccessToken(user),
    refreshToken: refresh.token,
    expiresAt: refresh.expiresAt.toISOString(),
    ...extra,
  };
}
