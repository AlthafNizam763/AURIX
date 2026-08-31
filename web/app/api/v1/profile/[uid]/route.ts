import { ok } from '@/server/http/respond';
import { withSelf } from '@/server/middleware/auth';
import { accountView, requireUser } from '@/server/services/users';

/**
 * A profile by uid.
 *
 * **The only route in the API that takes a uid from its path**, and therefore
 * the only one that needs `withSelf` — which asserts the parameter names the
 * caller before the handler runs. Every other per-user query derives the uid
 * from the token, which is what makes "read someone else's library" a query the
 * client cannot phrase rather than a rule it might talk past.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export const GET = withSelf<{ uid: string }>(async (_request, { params }) =>
  ok({ user: await accountView(await requireUser((await params).uid)) }),
);
