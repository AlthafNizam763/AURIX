'use server';

import { redirect } from 'next/navigation';

import { endSession } from '@/server/admin/session';

/** Ends the portal session and returns to the login screen. */
export async function signOut(): Promise<void> {
  await endSession();
  redirect('/admin/login');
}
