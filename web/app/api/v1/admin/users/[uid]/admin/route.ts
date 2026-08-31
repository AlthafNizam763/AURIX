import { collections } from '@/server/db/mongo';
import { ok } from '@/server/http/respond';
import { S, body, z } from '@/server/http/validate';
import { withAdmin } from '@/server/middleware/auth';
import { accountView } from '@/server/services/users';
import { badRequest, notFound } from '@/server/utils/errors';
import { log } from '@/server/utils/logger';

/**
 * Grants or revokes administrator access.
 *
 * **Refuses to remove the last administrator.** Without that check a deployment
 * can lock itself out of its own theme configuration with one click, and the
 * only way back is a Mongo shell.
 */
export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const schema = z.object({ isAdmin: z.boolean() });

export const POST = withAdmin<{ uid: string }>(async (request, { auth, params }) => {
  const uid = S.uid.parse((await params).uid);
  const { isAdmin } = await body(request, schema);

  const users = await collections.users();

  if (!isAdmin) {
    const admins = await users.countDocuments({ isAdmin: true });
    const target = await users.findOne({ uid }, { projection: { isAdmin: 1 } });
    if (target?.isAdmin && admins <= 1) {
      throw badRequest('That is the only administrator — promote another account first.');
    }
  }

  const updated = await users.findOneAndUpdate(
    { uid },
    { $set: { isAdmin, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
  if (!updated) throw notFound('No such account.');

  log.info(`${auth.uid} set isAdmin=${isAdmin} on ${uid}`, 'admin');
  return ok({ user: await accountView(updated) });
});
