import { env } from '@/server/config/env';
import { handler, ok } from '@/server/http/respond';
import { body, deviceField, z } from '@/server/http/validate';
import { LIMITS, enforce } from '@/server/middleware/rate-limit';
import { signInMethodsFor } from '@/server/services/identities';
import { peekGrant, takeGrant } from '@/server/services/oauth/flow';
import { providerLabel } from '@/server/services/oauth/providers';
import { maskEmail } from '@/server/services/phone';
import { buildSession } from '@/server/services/session';
import { requireUser } from '@/server/services/users';

/**
 * Redeems the grant the browser came home with.
 *
 * Two possible answers, and the client branches on `linkRequired`:
 *
 *  * a **session**, in the same shape every other sign-in produces; or
 *  * a **link challenge** — this provider account maps to an existing AURIX
 *    user, and the caller has to prove they own it before the two are joined.
 *
 * A session grant is spent here (`takeGrant` — the delete *is* the check, so two
 * devices racing the same code cannot both win). A link grant is only peeked at,
 * because the challenge is a conversation that continues at `/auth/link/*`.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({
  code: z.string().trim().min(1).max(512),
  device: deviceField,
});

export const POST = handler(async (request) => {
  const headers = await enforce(LIMITS.oauthExchange, request);
  const { code, device } = await body(request, schema);

  const record = await peekGrant(code);

  if (record.kind === 'session') {
    await takeGrant(code, 'session');
    const user = await requireUser(String(record.uid));
    return ok(
      await buildSession(user, {
        device: device ?? record.payload?.device,
        provider: record.provider,
        created: record.payload?.created === true,
        linked: record.payload?.linked === true,
      }),
      200,
      headers,
    );
  }

  const owner = await requireUser(String(record.uid));
  return ok(
    {
      linkRequired: true,
      linkToken: code,
      provider: record.provider,
      providerLabel: providerLabel(record.provider),
      // Masked: enough for the owner to recognise their own account, not enough
      // to learn a stranger's address from a provider sign-in.
      email: maskEmail(owner.email),
      hasPassword: typeof owner.passwordHash === 'string' && owner.passwordHash.length > 0,
      methods: await signInMethodsFor(owner),
      expiresInSeconds: env.oauthGrantMinutes * 60,
    },
    200,
    headers,
  );
});
