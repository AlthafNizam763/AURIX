import type { Metadata } from 'next';
import { redirect } from 'next/navigation';

import { currentAdmin } from '@/server/admin/session';

import { LoginForm } from './login-form';

export const metadata: Metadata = { title: 'Sign in' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * The portal's front door.
 *
 * Outside the guarded layout, which is why it lives at `/admin/login` with its
 * own page rather than inside the shell — a login screen wrapped in navigation
 * that requires a session is a redirect loop.
 */
export default async function LoginPage() {
  // Already signed in: skip the form rather than asking someone to authenticate
  // twice.
  if (await currentAdmin()) redirect('/admin');

  return (
    <main className="flex min-h-dvh items-center justify-center px-6 py-16">
      <div className="w-full max-w-sm">
        <div className="mb-10 text-center">
          <p className="text-[11px] tracking-[0.45em] text-ink-tertiary uppercase">AURIX</p>
          <h1 className="mt-3 text-2xl font-semibold tracking-tight">Administration</h1>
          <p className="mt-2 text-sm text-ink-secondary">
            Sign in with an administrator account.
          </p>
        </div>

        <LoginForm />

        <p className="mt-8 text-center text-xs text-ink-tertiary">
          Administrator access is granted from within the portal. The first one comes
          from <code className="font-mono">BOOTSTRAP_ADMIN_EMAIL</code>.
        </p>
      </div>
    </main>
  );
}
