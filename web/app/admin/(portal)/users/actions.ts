'use server';

import { revalidatePath } from 'next/cache';

import { requireAdmin } from '@/server/admin/session';
import { collections } from '@/server/db/mongo';
import { log } from '@/server/utils/logger';

/**
 * Granting and revoking administrator access.
 *
 * ## The guard is repeated on purpose
 *
 * `requireAdmin()` runs here even though the layout above already called it. A
 * Server Action is a POST endpoint that Next.js exposes on the page's URL — it
 * does **not** re-run the layout — so an action that trusted the surrounding
 * page would be an unauthenticated mutation reachable by anyone who could guess
 * its identifier.
 */

export interface RoleState {
  error?: string;
  message?: string;
}

export async function setAdmin(_previous: RoleState, formData: FormData): Promise<RoleState> {
  const actor = await requireAdmin();

  const uid = String(formData.get('uid') ?? '');
  const isAdmin = String(formData.get('isAdmin') ?? '') === 'true';
  if (!uid) return { error: 'No account was named.' };

  const users = await collections.users();

  if (!isAdmin) {
    // Refuses to remove the last administrator. Without this check a deployment
    // can lock itself out of its own configuration with one click, and the only
    // way back is a Mongo shell.
    const admins = await users.countDocuments({ isAdmin: true });
    const target = await users.findOne({ uid }, { projection: { isAdmin: 1 } });
    if (target?.isAdmin && admins <= 1) {
      return { error: 'That is the only administrator — promote another account first.' };
    }
  }

  const updated = await users.findOneAndUpdate(
    { uid },
    { $set: { isAdmin, updatedAt: new Date() } },
    { returnDocument: 'after' },
  );
  if (!updated) return { error: 'No such account.' };

  log.info(`${actor.uid} set isAdmin=${isAdmin} on ${uid}`, 'admin');

  // The list is rendered from the database on every request, so this is what
  // makes the change visible without a manual reload.
  revalidatePath('/admin/users');

  const who = updated.name || updated.email || uid;
  return {
    message: isAdmin ? `${who} is now an administrator.` : `${who} is no longer an administrator.`,
  };
}
