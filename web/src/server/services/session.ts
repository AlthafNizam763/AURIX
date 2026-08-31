import type { UserDoc } from '../db/documents';
import { issueAccessToken, issueRefreshToken } from './tokens';
import { accountView, type PublicUser } from './users';

/**
 * The one shape a successful authentication has, whichever door it came in by.
 *
 * ## Why this is a module and not eight copies of five lines
 *
 * AURIX has six ways to become signed in — a password, a phone code, and four
 * social providers — plus a refresh and an account link that also mint
 * sessions. The client has exactly one piece of code that reads the result, and
 * it is `ApiAuthService._storeSession`: it expects `user`, `accessToken`,
 * `refreshToken` and `expiresAt`, stores them, and emits a session change.
 *
 * That only holds while every path produces the identical payload. A route that
 * assembled its own — omitting `expiresAt`, say, or returning `publicUser`
 * where every other path returns an [accountView] with the linked providers
 * filled in — would work in isolation and quietly produce an account that
 * appears to have no Google linked the moment you signed in with Google.
 *
 * So: **no route builds a session. They all call this.**
 *
 * ## What is deliberately *not* here
 *
 * Any hint of how the user authenticated. The token carries a uid, an email and
 * an admin flag, and nothing about whether a password or an Apple ID was
 * involved — because nothing downstream should behave differently. A playlist
 * write does not care, and a route that did care would be a route that treats
 * some accounts as second class.
 *
 * The optional extras below are the exception that proves it: `provider`,
 * `created` and `linked` describe *this sign-in* for the benefit of the screen
 * that is about to be drawn, and none of them is persisted or consulted again.
 */

export interface Session {
  user: PublicUser;
  accessToken: string;
  refreshToken: string;
  /** ISO-8601. The refresh token's expiry, not the access token's. */
  expiresAt: string;
  device?: string | null;
  provider?: string;
  created?: boolean;
  linked?: boolean;
}

export interface SessionExtras {
  device?: string | null;
  provider?: string;
  created?: boolean;
  linked?: boolean;
}

export async function buildSession(
  user: UserDoc,
  { device, ...extra }: SessionExtras = {},
): Promise<Session> {
  const refresh = await issueRefreshToken(user.uid, { device });
  return {
    user: await accountView(user),
    accessToken: issueAccessToken(user),
    refreshToken: refresh.token,
    expiresAt: refresh.expiresAt.toISOString(),
    ...extra,
  };
}
