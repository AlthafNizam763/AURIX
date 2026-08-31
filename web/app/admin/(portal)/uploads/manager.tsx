'use client';

import { useActionState } from 'react';

import {
  Badge,
  EmptyState,
  Field,
  Notice,
  Panel,
  TableShell,
  Td,
  Th,
  buttonStyles,
  inputStyles,
} from '@components/ui';

import { deleteFont, uploadFont, type UploadState } from './actions';

interface FontFile {
  id: string;
  url: string;
  family: string;
  contentType: string;
  length: number;
  uploadedAt: string | null;
}

function size(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${Math.round(bytes / 1024)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export function UploadsManager({
  fonts,
  activeFamily,
  maxBytes,
}: {
  fonts: FontFile[];
  activeFamily: string;
  maxBytes: number;
}) {
  const [state, action, pending] = useActionState<UploadState, FormData>(uploadFont, {});

  return (
    <div className="space-y-6">
      <Panel
        title="Add a font"
        description={`TTF, OTF, WOFF or WOFF2, up to ${size(maxBytes)}. The family name is how the app refers to it.`}
      >
        <form action={action} className="space-y-4">
          {state.error ? <Notice tone="error">{state.error}</Notice> : null}
          {state.message ? <Notice tone="success">{state.message}</Notice> : null}

          <div className="grid gap-4 sm:grid-cols-2">
            <Field
              label="Family name"
              hint="Uploading the same family again replaces the previous file."
            >
              <input
                className={inputStyles}
                type="text"
                name="family"
                placeholder="Manrope"
                maxLength={64}
                required
              />
            </Field>

            <Field label="File">
              <input
                type="file"
                name="file"
                accept=".ttf,.otf,.woff,.woff2,font/ttf,font/otf,font/woff,font/woff2"
                required
                className="block w-full text-xs text-ink-secondary file:mr-3 file:rounded-lg file:border-0 file:bg-surface-elevated file:px-3 file:py-2 file:text-xs file:text-ink"
              />
            </Field>
          </div>

          <label className="flex items-center gap-2 text-sm text-ink-secondary">
            <input type="checkbox" name="apply" className="accent-white" />
            Apply this family to the app immediately
          </label>

          <button type="submit" className={buttonStyles.primary} disabled={pending}>
            {pending ? 'Uploading…' : 'Upload font'}
          </button>
        </form>
      </Panel>

      <Panel title="Uploaded fonts">
        {fonts.length === 0 ? (
          <EmptyState
            title="No fonts uploaded."
            hint="The six bundled families work without any of this — they ship inside the app."
          />
        ) : (
          <TableShell>
            <thead>
              <tr>
                <Th>Family</Th>
                <Th className="hidden sm:table-cell">Type</Th>
                <Th>Size</Th>
                <Th className="text-right">Actions</Th>
              </tr>
            </thead>
            <tbody>
              {fonts.map((font) => (
                <tr key={font.id}>
                  <Td>
                    <p className="font-medium">
                      {font.family}
                      {font.family === activeFamily ? (
                        <span className="ml-2 align-middle">
                          <Badge>In use</Badge>
                        </span>
                      ) : null}
                    </p>
                    <p className="truncate text-xs text-ink-tertiary">
                      {font.uploadedAt?.slice(0, 10) ?? '—'}
                    </p>
                  </Td>
                  <Td className="hidden sm:table-cell">
                    <Badge muted>{font.contentType.replace('font/', '')}</Badge>
                  </Td>
                  <Td className="tabular-nums text-ink-secondary">{size(font.length)}</Td>
                  <Td className="text-right">
                    <DeleteFont id={font.id} inUse={font.family === activeFamily} />
                  </Td>
                </tr>
              ))}
            </tbody>
          </TableShell>
        )}
      </Panel>
    </div>
  );
}

function DeleteFont({ id, inUse }: { id: string; inUse: boolean }) {
  const [state, action, pending] = useActionState<UploadState, FormData>(deleteFont, {});

  return (
    <div className="flex flex-col items-end gap-2">
      <form action={action}>
        <input type="hidden" name="id" value={id} />
        <button type="submit" className={buttonStyles.ghost} disabled={pending}>
          {pending ? '…' : 'Delete'}
        </button>
      </form>

      {inUse ? (
        // Deleting the active family is allowed — the app falls back to a
        // bundled face rather than rendering nothing — but it is worth saying.
        <span className="text-[11px] text-ink-tertiary">Currently applied</span>
      ) : null}

      {state.error ? (
        <div className="max-w-xs text-left">
          <Notice tone="error">{state.error}</Notice>
        </div>
      ) : null}
    </div>
  );
}
