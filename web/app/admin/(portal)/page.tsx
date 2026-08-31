import type { Metadata } from 'next';
import Link from 'next/link';

import { requireAdmin } from '@/server/admin/session';
import { collections } from '@/server/db/mongo';
import { readTheme } from '@/server/services/theme';
import { PageHeader, Panel, StatTile, buttonStyles } from '@components/ui';

export const metadata: Metadata = { title: 'Dashboard' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * The dashboard.
 *
 * Reads the counts directly rather than fetching `GET /api/v1/admin/stats`. The
 * route still exists and is still the API's answer to the same question — but
 * this page runs *inside* the deployment, so calling it over HTTP would be a
 * request to ourselves, complete with a second TLS handshake and a second
 * database connection, to obtain numbers the same process can count.
 *
 * The trade is that the two must not drift. They will not, because both count
 * the same collections with no filter, and the counts are the whole answer.
 */
export default async function Dashboard() {
  const admin = await requireAdmin();

  const [users, likedTracks, userPlaylists, globalPlaylists, catalogSongs] = await Promise.all([
    collections.users(),
    collections.likedTracks(),
    collections.userPlaylists(),
    collections.globalPlaylists(),
    collections.catalogSongs(),
  ]);

  const [total, admins, liked, playlists, shared, songs, theme] = await Promise.all([
    users.countDocuments(),
    users.countDocuments({ isAdmin: true }),
    likedTracks.countDocuments(),
    userPlaylists.countDocuments(),
    globalPlaylists.countDocuments(),
    catalogSongs.countDocuments(),
    readTheme(),
  ]);

  return (
    <>
      <PageHeader
        eyebrow="Overview"
        title={`Good to see you, ${admin.name.split(' ')[0] || 'there'}`}
        description="Everything AURIX is storing, right now."
      />

      <div className="grid grid-cols-2 gap-3 sm:gap-4 lg:grid-cols-3">
        <StatTile label="Accounts" value={total} hint={`${admins} administrator${admins === 1 ? '' : 's'}`} />
        <StatTile label="Songs" value={songs} hint="Shared catalogue" />
        <StatTile label="Shared playlists" value={shared} hint="Imported by users" />
        <StatTile label="User playlists" value={playlists} hint="Private to their owners" />
        <StatTile label="Liked tracks" value={liked} hint="Across all accounts" />
        <StatTile label="Theme version" value={theme.version ?? 1} hint="Bumped on every change" />
      </div>

      <div className="mt-8 grid gap-4 lg:grid-cols-2">
        <Panel
          title="Managing the catalogue"
          description="What this portal can and cannot change."
        >
          <div className="space-y-3 text-sm text-ink-secondary">
            <p>
              Songs and shared playlists are <strong className="text-ink">read-only</strong>{' '}
              here. They are contributed by users when they import, and the API has no
              endpoint that deletes a catalogue song — a shared playlist can only be
              withdrawn by the account that added it.
            </p>
            <p>
              Accounts and appearance are fully editable, because those are the two
              things an operator genuinely owns.
            </p>
          </div>
        </Panel>

        <Panel title="Quick actions">
          <div className="flex flex-wrap gap-2">
            <Link href="/admin/users" className={buttonStyles.secondary}>
              Manage accounts
            </Link>
            <Link href="/admin/appearance" className={buttonStyles.secondary}>
              Edit appearance
            </Link>
            <Link href="/admin/songs" className={buttonStyles.secondary}>
              Browse songs
            </Link>
          </div>
        </Panel>
      </div>
    </>
  );
}
