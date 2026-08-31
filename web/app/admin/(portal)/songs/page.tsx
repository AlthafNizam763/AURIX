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

export const metadata: Metadata = { title: 'Songs' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const PAGE_SIZE = 50;
const SEARCH_FANOUT = 4;

/** `200040` → `3:20`. */
function duration(ms: number): string {
  if (!ms || ms <= 0) return '—';
  const total = Math.round(ms / 1000);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

/**
 * The shared song catalogue.
 *
 * **Read-only, and that is a statement about the data rather than a gap in the
 * portal.** These rows are contributed by users when they import; the API has no
 * endpoint that deletes one, and adding a delete here would mean inventing a
 * capability — and a consequence — the rest of the system has never had. A song
 * removed from under a playlist that references it is a broken playlist for
 * whoever imported it.
 *
 * Uses the same index-plus-residual search the API does, so what an
 * administrator sees is what a user's search returns.
 */
export default async function SongsPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  await requireAdmin();

  const { q } = await searchParams;
  const search = (q ?? '').trim();

  const songs = await collections.catalogSongs();
  const total = await songs.estimatedDocumentCount();

  let rows;
  if (search) {
    const token = queryToken(search);
    const residual = residualWords(search);

    rows = token
      ? (
          await songs
            .find({ searchTokens: token })
            .limit(residual.length === 0 ? PAGE_SIZE : PAGE_SIZE * SEARCH_FANOUT)
            .toArray()
        )
          .filter((row) =>
            matchesResidual(
              normaliseAlbum(
                `${row.title ?? ''} ${(row.artists ?? []).join(', ')} ${row.album ?? ''}`,
              ),
              residual,
            ),
          )
          .slice(0, PAGE_SIZE)
      : [];
  } else {
    // No query: the most recently touched rows, which is the useful default for
    // "what has been arriving".
    rows = await songs.find({}).sort({ updatedAt: -1 }).limit(PAGE_SIZE).toArray();
  }

  return (
    <>
      <PageHeader
        eyebrow="Catalogue"
        title="Songs"
        description={`${total.toLocaleString()} songs, contributed by users as they import.`}
      />

      <div className="mb-4">
        <Notice>
          Read-only. Songs are written by the app when a user imports, and there is no
          endpoint that deletes one — removing a song would break every playlist that
          references it.
        </Notice>
      </div>

      <Panel>
        <form method="get" className="mb-5 flex gap-2">
          <input
            className={inputStyles}
            type="search"
            name="q"
            defaultValue={search}
            placeholder="Search title, artist or album…"
            aria-label="Search songs"
          />
          <button type="submit" className={buttonStyles.secondary}>
            Search
          </button>
        </form>

        {rows.length === 0 ? (
          <EmptyState
            title={search ? `Nothing matches “${search}”.` : 'The catalogue is empty.'}
            hint={
              search
                ? 'Search matches the start of a word, the way it does in the app.'
                : 'Songs appear here as users import them.'
            }
          />
        ) : (
          <TableShell>
            <thead>
              <tr>
                <Th>Title</Th>
                <Th className="hidden sm:table-cell">Album</Th>
                <Th>Length</Th>
                <Th className="hidden md:table-cell">Source</Th>
              </tr>
            </thead>
            <tbody>
              {rows.map((song) => (
                <tr key={String(song._id)}>
                  <Td>
                    <div className="min-w-0">
                      <p className="truncate font-medium">
                        {song.title}
                        {song.explicit ? (
                          <span className="ml-2 align-middle">
                            <Badge muted>E</Badge>
                          </span>
                        ) : null}
                      </p>
                      <p className="truncate text-xs text-ink-tertiary">
                        {(song.artists ?? []).join(', ') || 'Unknown artist'}
                      </p>
                    </div>
                  </Td>
                  <Td className="hidden max-w-[16rem] truncate text-ink-secondary sm:table-cell">
                    {song.album || '—'}
                  </Td>
                  <Td className="tabular-nums text-ink-secondary">{duration(song.duration)}</Td>
                  <Td className="hidden md:table-cell">
                    <Badge muted>{song.source || 'aurix'}</Badge>
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
