'use server';

import { redirect } from 'next/navigation';

import { startSession } from '@/server/admin/session';
import { LIMITS, consume } from '@/server/middleware/rate-limit';
import { userByEmail, verifyPassword } from '@/server/services/users';
import { log } from '@/server/utils/logger';
import { headers } from 'next/headers';

/**
 * Signing in to the portal.
 *
 * ## Why this does not call `POST /api/v1/auth/login`
 *
 * It would be an HTTP round trip from the deployment to itself, and it would
 * mint an API access token the portal has no safe place to keep. The portal is
 * a first-party server-rendered application, not an API client, so it verifies
 * the password against the same service the API route uses and issues its own
 * cookie. See `server/admin/session` for the full reasoning.
 *
 * The security-relevant behaviours of the API route are reproduced here rather
 * than inherited, and they are the ones worth listing:
 *
 *  * bcrypt runs whether or not the account exists, so response timing does not
 *    disclose which addresses are registered;
 *  * one message for a wrong password, an unknown address and a non-admin
 *    account alike — the portal must not become a way to enumerate either
 *    accounts or *administrators*;
 *  * the attempt is rate limited per IP against the same shared counter the API
 *    uses, so an attacker cannot double their budget by alternating between the
 *    two doors.
 */

export interface LoginState {
  error?: string;
}

export async function signIn(_previous: LoginState, formData: FormData): Promise<LoginState> {
  const email = String(formData.get('email') ?? '').trim().toLowerCase();
  const password = String(formData.get('password') ?? '');

  if (!email || !password) {
    return { error: 'Enter an email address and a password.' };
  }

  // The same bucket the API's login route counts against — `LIMITS.credentials`
  // — keyed on the same address. Two doors into one account must not mean twice
  // the guesses.
  const forwarded = (await headers()).get('x-forwarded-for');
  const client = forwarded?.split(',')[0]?.trim() || 'unknown';

  const limit = await consume(LIMITS.credentials, client);
  if (!limit.allowed) {
    return { error: 'Too many attempts. Try again in a few minutes.' };
  }

  const user = await userByEmail(email);

  // Runs even when there is no account, so the response takes the same time
  // either way.
  const passwordOk = await verifyPassword(password, user?.passwordHash ?? '');

  // One message for all three failures. Distinguishing "not an administrator"
  // from "wrong password" would turn this form into a way to discover which
  // accounts are privileged.
  if (!user || !passwordOk || !user.isAdmin) {
    if (user && passwordOk && !user.isAdmin) {
      // Worth a log line: somebody with valid credentials tried the admin door.
      log.warn(`Non-admin ${user.uid} attempted to sign in to the portal`, 'admin');
    }
    return { error: 'Those details do not match an administrator account.' };
  }

  await startSession(user);
  log.info(`Admin ${user.uid} signed in to the portal`, 'admin');

  redirect('/admin');
}
