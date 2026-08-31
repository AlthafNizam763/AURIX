import type { Metadata } from 'next';
import type { Filter } from 'mongodb';

import { requireAdmin } from '@/server/admin/session';
import type { UserDoc } from '@/server/db/documents';
import { collections } from '@/server/db/mongo';
import { accountViews } from '@/server/services/users';
import {
  Badge,
  EmptyState,
  PageHeader,
  Panel,
  TableShell,
  Td,
  Th,
  buttonStyles,
  inputStyles,
} from '@components/ui';

import { RoleToggle } from './role-toggle';

export const metadata: Metadata = { title: 'Users' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const PAGE_SIZE = 50;

/**
 * Escapes a search string for use inside a `$regex`.
 *
 * The same function the API route carries, and for the same reason: an
 * unescaped user string in a regex is a denial of service waiting to happen —
 * `(a+)+$` against a long field is the classic catastrophic-backtracking case —
 * and the `^` anchor is what lets the query use an index instead of scanning
 * every account.
 */
function escapeRegex(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export default async function UsersPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  const admin = await requireAdmin();
  const { q } = await searchParams;
  const search = (q ?? '').trim();

  const filter: Filter<UserDoc> = search
    ? {
        $or: [
          { email: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
          { name: { $regex: `^${escapeRegex(search)}`, $options: 'i' } },
        ],
      }
    : {};

  const users = await collections.users();
  const rows = await users
    .find(filter)
    .sort({ createdAt: -1 })
    .limit(PAGE_SIZE)
    .toArray();

  // Batched — two queries rather than 2N, because each account's linked
  // providers live in a separate collection.
  const accounts = await accountViews(rows);
  const total = await users.countDocuments(filter);

  return (
    <>
      <PageHeader
        eyebrow="Accounts"
        title="Users"
        description="Every AURIX account, newest first. Search matches the start of an email address or a name."
      />

      <Panel>
        <form method="get" className="mb-5 flex gap-2">
          <input
            className={inputStyles}
            type="search"
            name="q"
            defaultValue={search}
            placeholder="Search by email or name…"
            aria-label="Search accounts"
          />
          <button type="submit" className={buttonStyles.secondary}>
            Search
          </button>
        </form>

        {accounts.length === 0 ? (
          <EmptyState
            title={search ? `No account starts with “${search}”.` : 'No accounts yet.'}
            hint={search ? 'Search matches the beginning of a field, not the middle.' : undefined}
          />
        ) : (
          <>
            <TableShell>
              <thead>
                <tr>
                  <Th>Account</Th>
                  <Th className="hidden sm:table-cell">Sign-in methods</Th>
                  <Th>Role</Th>
                  <Th className="text-right">Actions</Th>
                </tr>
              </thead>
              <tbody>
                {accounts.map((account) => (
                  <tr key={account.uid}>
                    <Td>
                      <div className="min-w-0">
                        <p className="truncate font-medium">
                          {account.name || <span className="text-ink-tertiary">No name</span>}
                        </p>
                        <p className="truncate text-xs text-ink-tertiary">
                          {account.email || account.phone || account.uid}
                        </p>
                      </div>
                    </Td>
                    <Td className="hidden sm:table-cell">
                      <div className="flex flex-wrap gap-1">
                        {account.providers.map((provider) => (
                          <Badge key={provider} muted>
                            {provider}
                          </Badge>
                        ))}
                      </div>
                    </Td>
                    <Td>
                      {account.isAdmin ? <Badge>Administrator</Badge> : <span className="text-ink-tertiary">User</span>}
                    </Td>
                    <Td className="text-right">
                      <RoleToggle
                        uid={account.uid}
                        isAdmin={account.isAdmin}
                        // An administrator demoting themselves would be logged
                        // out by their next click. Refusing here is kinder than
                        // letting them discover that.
                        isSelf={account.uid === admin.uid}
                      />
                    </Td>
                  </tr>
                ))}
              </tbody>
            </TableShell>

            {total > accounts.length ? (
              <p className="mt-4 text-xs text-ink-tertiary">
                Showing {accounts.length} of {total.toLocaleString()}. Narrow the list with
                a search.
              </p>
            ) : null}
          </>
        )}
      </Panel>
    </>
  );
}
