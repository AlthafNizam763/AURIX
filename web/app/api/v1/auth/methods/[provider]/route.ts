import { z } from 'zod';

import { withAuth } from '@/server/middleware/auth';
import { ok } from '@/server/http/respond';
import { detachIdentity } from '@/server/services/identities';
import { accountView, requireUser } from '@/server/services/users';
import { log } from '@/server/utils/logger';

/**
 * Removes a way in.
 *
 * Refuses to remove the last one — see `detachIdentity`, where the reasoning
 * lives. The failure mode it guards against is permanent: an account with no
 * identity left has no sign-in path and no recovery path either.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const providerParam = z.enum(['password', 'phone', 'google', 'apple', 'facebook', 'github']);

export const DELETE = withAuth<{ provider: string }>(async (_request, { auth, params }) => {
  const provider = providerParam.parse((await params).provider);

  await detachIdentity({ uid: auth.uid, provider });
  log.info(`Unlinked ${provider} from ${auth.uid}`, 'auth');

  return ok({ user: await accountView(await requireUser(auth.uid)) });
});
