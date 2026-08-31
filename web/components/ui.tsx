import type { ReactNode } from 'react';

/**
 * The portal's shared primitives.
 *
 * One small file rather than a component library. The portal is seven screens
 * that all show a heading, a panel and a table, and splitting that into a
 * directory of one-export files would be more ceremony than the surface
 * justifies.
 *
 * Everything here is a Server Component. Nothing in the portal needs client
 * JavaScript except the two forms that report a pending state, which mark
 * themselves `'use client'` explicitly.
 */

export function cx(...values: (string | false | null | undefined)[]): string {
  return values.filter(Boolean).join(' ');
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

export function PageHeader({
  eyebrow,
  title,
  description,
  actions,
}: {
  eyebrow?: string;
  title: string;
  description?: string;
  actions?: ReactNode;
}) {
  return (
    <header className="mb-8 flex flex-wrap items-end justify-between gap-4">
      <div>
        {eyebrow ? (
          <p className="mb-2 text-[11px] tracking-[0.35em] text-ink-tertiary uppercase">
            {eyebrow}
          </p>
        ) : null}
        <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">{title}</h1>
        {description ? (
          <p className="mt-2 max-w-2xl text-sm text-ink-secondary">{description}</p>
        ) : null}
      </div>
      {actions ? <div className="flex items-center gap-2">{actions}</div> : null}
    </header>
  );
}

export function Panel({
  title,
  description,
  children,
  className,
}: {
  title?: string;
  description?: string;
  children: ReactNode;
  className?: string;
}) {
  return (
    <section
      className={cx(
        'rounded-xl border border-hairline bg-surface/60 backdrop-blur-sm',
        className,
      )}
    >
      {title ? (
        <div className="border-b border-hairline px-5 py-4">
          <h2 className="text-sm font-semibold tracking-tight">{title}</h2>
          {description ? (
            <p className="mt-1 text-xs text-ink-secondary">{description}</p>
          ) : null}
        </div>
      ) : null}
      <div className="p-5">{children}</div>
    </section>
  );
}

/** A dashboard number. Deliberately large — it is the whole content of the tile. */
export function StatTile({
  label,
  value,
  hint,
}: {
  label: string;
  value: number | string;
  hint?: string;
}) {
  return (
    <div className="rounded-xl border border-hairline bg-surface/60 p-5">
      <p className="text-[11px] tracking-[0.2em] text-ink-tertiary uppercase">{label}</p>
      <p className="mt-3 text-3xl font-semibold tabular-nums tracking-tight">
        {typeof value === 'number' ? value.toLocaleString() : value}
      </p>
      {hint ? <p className="mt-1 text-xs text-ink-tertiary">{hint}</p> : null}
    </div>
  );
}

export function EmptyState({ title, hint }: { title: string; hint?: string }) {
  return (
    <div className="rounded-lg border border-dashed border-hairline px-6 py-12 text-center">
      <p className="text-sm text-ink-secondary">{title}</p>
      {hint ? <p className="mt-1 text-xs text-ink-tertiary">{hint}</p> : null}
    </div>
  );
}

/**
 * A message that is not an error.
 *
 * `tone` exists because "the only administrator cannot be demoted" and "that
 * password is not correct" want to read differently from "saved".
 */
export function Notice({
  tone = 'info',
  children,
}: {
  tone?: 'info' | 'error' | 'success';
  children: ReactNode;
}) {
  const tones = {
    info: 'border-hairline-strong text-ink-secondary',
    error: 'border-ink/40 text-ink',
    success: 'border-ink/25 text-ink-secondary',
  };
  return (
    <p
      role={tone === 'error' ? 'alert' : 'status'}
      className={cx('rounded-lg border px-4 py-3 text-sm', tones[tone])}
    >
      {children}
    </p>
  );
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

/**
 * A table that scrolls inside its own box.
 *
 * The wrapper is not decoration: a wide table on a narrow screen must scroll
 * itself rather than making the whole page scroll sideways.
 */
export function TableShell({ children }: { children: ReactNode }) {
  return (
    <div className="-mx-5 overflow-x-auto px-5">
      <table className="w-full min-w-[36rem] border-collapse text-sm">{children}</table>
    </div>
  );
}

export function Th({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <th
      scope="col"
      className={cx(
        'border-b border-hairline pb-3 text-left text-[11px] font-medium',
        'tracking-[0.15em] text-ink-tertiary uppercase',
        className,
      )}
    >
      {children}
    </th>
  );
}

export function Td({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <td className={cx('border-b border-hairline py-3 align-middle', className)}>
      {children}
    </td>
  );
}

export function Badge({ children, muted }: { children: ReactNode; muted?: boolean }) {
  return (
    <span
      className={cx(
        'inline-flex items-center rounded-full border px-2 py-0.5 text-[11px]',
        muted
          ? 'border-hairline text-ink-tertiary'
          : 'border-ink/30 text-ink',
      )}
    >
      {children}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

const buttonBase =
  'inline-flex items-center justify-center gap-2 rounded-lg px-4 py-2 text-sm ' +
  'font-medium transition-colors disabled:cursor-not-allowed disabled:opacity-50';

export const buttonStyles = {
  primary: cx(buttonBase, 'bg-accent text-on-accent hover:bg-accent-pressed'),
  secondary: cx(
    buttonBase,
    'border border-hairline-strong text-ink hover:bg-surface-elevated',
  ),
  ghost: cx(buttonBase, 'text-ink-secondary hover:text-ink'),
};

export function Field({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <label className="block">
      <span className="mb-1.5 block text-xs font-medium text-ink-secondary">{label}</span>
      {children}
      {hint ? <span className="mt-1 block text-xs text-ink-tertiary">{hint}</span> : null}
    </label>
  );
}

export const inputStyles = cx(
  'w-full rounded-lg border border-hairline-strong bg-ground-deep px-3 py-2',
  'text-sm text-ink placeholder:text-ink-tertiary',
  'focus:border-ink/40 focus:outline-none',
);
