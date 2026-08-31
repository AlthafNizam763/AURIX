import { created, handler } from '@/server/http/respond';
import { S, body, deviceField, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { sendEmailVerification } from '@/server/services/mailer';
import { buildSession } from '@/server/services/session';
import { ACTION, issueActionToken } from '@/server/services/tokens';
import { createUser } from '@/server/services/users';
import { log } from '@/server/utils/logger';
import { after } from 'next/server';

/**
 * Registration.
 *
 * Rate limited per IP. Firebase applied these limits on Google's side and the
 * app never had to think about them; now they are ours, and they are counted in
 * MongoDB rather than in process memory because a serverless instance's memory
 * is not a shared counter. See `middleware/rate-limit`.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  email: S.email,
  password: S.password,
  name: S.displayName,
  device: deviceField,
});

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.credentials, request);
  const { email, password, name, device } = await body(request, schema);

  const user = await createUser({ email, password, name });

  // Fire-and-forget: a verification email that fails to send must not fail the
  // registration. The account exists, the user is signed in, and the app offers
  // "resend" on the profile screen.
  //
  // `after()` rather than a bare floating promise. On a long-lived server the
  // event loop kept running and the promise resolved on its own; a serverless
  // instance may be frozen the moment the response is returned, so detached work
  // has to be handed to the platform explicitly or it simply never happens.
  after(async () => {
    try {
      const { token } = await issueActionToken(user.uid, ACTION.verifyEmail);
      await sendEmailVerification(user.email!, token);
    } catch (error) {
      log.warn('Could not start email verification', 'auth', error);
    }
  });

  log.info(`Registered ${user.email}${user.isAdmin ? ' (admin)' : ''}`, 'auth');

  return created(await buildSession(user, { device }), headers);
});
