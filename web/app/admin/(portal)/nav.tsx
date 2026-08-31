'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

import { cx } from '@components/ui';

/**
 * The portal's navigation.
 *
 * The second and last client component, and it is one only to read the current
 * path — marking the active link on the server would mean threading the pathname
 * through the layout on every render.
 *
 * ## What is here, and what deliberately is not
 *
 * Seven entries, each backed by a collection that actually exists. There is no
 * Albums, Artists or Genres, because AURIX has no such collections — songs carry
 * an `album` string and an `artists` array, and inventing screens over data the
 * database does not model would produce a portal that looks complete and manages
 * nothing.
 */
const LINKS = [
  { href: '/admin', label: 'Dashboard', exact: true },
  { href: '/admin/users', label: 'Users' },
  { href: '/admin/songs', label: 'Songs' },
  { href: '/admin/playlists', label: 'Playlists' },
  { href: '/admin/appearance', label: 'Appearance' },
  { href: '/admin/uploads', label: 'Uploads' },
  { href: '/admin/settings', label: 'Settings' },
];

export function Nav() {
  const pathname = usePathname();

  return (
    <nav aria-label="Portal sections">
      <ul className="flex gap-1 overflow-x-auto lg:flex-col lg:overflow-visible">
        {LINKS.map((link) => {
          const active = link.exact ? pathname === link.href : pathname.startsWith(link.href);
          return (
            <li key={link.href} className="shrink-0 lg:shrink">
              <Link
                href={link.href}
                aria-current={active ? 'page' : undefined}
                className={cx(
                  'block rounded-lg px-3 py-2 text-sm transition-colors',
                  active
                    ? 'bg-surface-elevated font-medium text-ink'
                    : 'text-ink-secondary hover:text-ink',
                )}
              >
                {link.label}
              </Link>
            </li>
          );
        })}
      </ul>
    </nav>
  );
}
