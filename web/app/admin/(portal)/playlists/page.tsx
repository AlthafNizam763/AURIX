import type { Metadata } from 'next';

import { requireAdmin } from '@/server/admin/session';
import { collections } from '@/server/db/mongo';
import {
  Badge,
  EmptyState,
  Notice,
  PageHeader,
  Panel,
  TableShell,
  Td,
  Th,
  buttonStyles,
  inputStyles,
} from '@components/ui';
import { matchesResidual, normaliseAlbum, queryToken, residualWords } from '@/server/utils/search';

export const metadata: Metadata = { title: 'Playlists' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const PAGE_SIZE = 50;
const SEARCH_FANOUT = 4;

function when(value: unknown): string {
  if (!(value instanceof Date)) return '—';
  return value.toISOString().slice(0, 10);
}

/**
 * The shared playlist catalogue.
 *
 * Read-only for a sharper reason than the songs screen. A shared playlist can be
 * withdrawn, but **only by the account that imported it** — that rule is
 * enforced in `DELETE /api/v1/shared-playlists/:id` and it is the one place
 * `importedByUserId` stops being provenance and starts being ownership. Giving
 * an administrator a delete button here would quietly overrule it.
 *
 * A user's *own* playlists are deliberately not listed at all: they are private
 * to their owner, and an operator has no reason to read them.
 */
export default async function PlaylistsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  await requireAdmin();

  const { q } = await searchParams;
  const search = (q ?? '').trim();

  const playlists = await collections.globalPlaylists();
  const total = await playlists.estimatedDocumentCount();

  let rows;
  if (search) {
    const token = queryToken(search);
    const residual = residualWords(search);

    rows = token
      ? (
          await playlists
            .find({ searchTokens: token })
            .limit(residual.length === 0 ? PAGE_SIZE : PAGE_SIZE * SEARCH_FANOUT)
            .toArray()
        )
          .filter((row) =>
            matchesResidual(row.searchTitle ?? normaliseAlbum(row.name ?? ''), residual),
          )
          .slice(0, PAGE_SIZE)
      : [];
  } else {
    rows = await playlists.find({}).sort({ importedAt: -1 }).limit(PAGE_SIZE).toArray();
  }

  return (
    <>
      <PageHeader
        eyebrow="Catalogue"
        title="Shared playlists"
        description={`${total.toLocaleString()} playlists, contributed by users and playable by everyone.`}
      />

      <div className="mb-4">
        <Notice>
          Read-only. A shared playlist can only be withdrawn by the account that
          imported it — that rule lives in the API, and a delete button here would
          overrule it. Users&rsquo; private playlists are not listed.
        </Notice>
      </div>

      <Panel>
        <form method="get" className="mb-5 flex gap-2">
          <input
            className={inputStyles}
            type="search"
            name="q"
            defaultValue={search}
            placeholder="Search playlist names…"
            aria-label="Search playlists"
          />
          <button type="submit" className={buttonStyles.secondary}>
            Search
          </button>
        </form>

        {rows.length === 0 ? (
          <EmptyState
            title={search ? `Nothing matches “${search}”.` : 'Nothing has been imported yet.'}
            hint={search ? undefined : 'Playlists appear here as users import them.'}
          />
        ) : (
          <TableShell>
            <thead>
              <tr>
                <Th>Playlist</Th>
                <Th>Tracks</Th>
                <Th className="hidden sm:table-cell">Source</Th>
                <Th className="hidden md:table-cell">Imported</Th>
              </tr>
            </thead>
            <tbody>
              {rows.map((playlist) => (
                <tr key={String(playlist._id)}>
                  <Td>
                    <div className="min-w-0">
                      <p className="truncate font-medium">
                        {playlist.name || <span className="text-ink-tertiary">Untitled</span>}
                      </p>
                      <p className="truncate text-xs text-ink-tertiary">
                        by {playlist.importedBy || 'an unnamed account'}
                      </p>
                    </div>
                  </Td>
                  <Td className="tabular-nums text-ink-secondary">
                    {(playlist.trackCount ?? 0).toLocaleString()}
                  </Td>
                  <Td className="hidden sm:table-cell">
                    <Badge muted>{playlist.source || 'aurix'}</Badge>
                  </Td>
                  <Td className="hidden text-xs text-ink-tertiary tabular-nums md:table-cell">
                    {when(playlist.importedAt)}
                  </Td>
                </tr>
              ))}
            </tbody>
          </TableShell>
        )}
      </Panel>
    </>
  );
}
