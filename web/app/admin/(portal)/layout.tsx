import Link from 'next/link';

import { requireAdmin } from '@/server/admin/session';
import { buttonStyles } from '@components/ui';

import { signOut } from './actions';
import { Nav } from './nav';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * The portal shell.
 *
 * ## Why this is a route group
 *
 * `(portal)` does not appear in any URL — the dashboard is still `/admin`. What
 * it buys is a layout that wraps every signed-in screen while leaving
 * `/admin/login` outside it, which matters because a login page wrapped in a
 * layout that requires a session is a redirect loop.
 *
 * ## The guard is here, and also everywhere else
 *
 * `requireAdmin()` runs once for the shell, and again inside every page and
 * every Server Action beneath it. That is not redundancy to be tidied away: a
 * layout in Next.js does **not** re-run before a Server Action, so a mutation
 * that trusted this guard alone would be an unauthenticated mutation. The rule
 * is that anything reading or writing checks for itself, and the layout's check
 * exists only to render the right chrome.
 */
export default async function PortalLayout({ children }: { children: React.ReactNode }) {
  const admin = await requireAdmin();

  return (
    <div className="min-h-dvh lg:grid lg:grid-cols-[16rem_1fr]">
      <aside
        className={
          'border-b border-hairline bg-ground-deep lg:sticky lg:top-0 lg:h-dvh ' +
          'lg:border-r lg:border-b-0'
        }
      >
        <div className="flex h-full flex-col p-5">
          <Link href="/admin" className="mb-8 block">
            <p className="text-[11px] tracking-[0.45em] text-ink-tertiary uppercase">AURIX</p>
            <p className="mt-1 text-sm font-semibold tracking-tight">Administration</p>
          </Link>

          <Nav />

          <div className="mt-8 border-t border-hairline pt-4 lg:mt-auto">
            <p className="truncate text-xs font-medium">{admin.name || 'Administrator'}</p>
            <p className="truncate text-xs text-ink-tertiary">{admin.email}</p>
            <form action={signOut} className="mt-3">
              <button type="submit" className={`${buttonStyles.secondary} w-full`}>
                Sign out
              </button>
            </form>
          </div>
        </div>
      </aside>

      <main className="min-w-0 px-5 py-8 sm:px-8 lg:px-10 lg:py-12">{children}</main>
    </div>
  );
}
