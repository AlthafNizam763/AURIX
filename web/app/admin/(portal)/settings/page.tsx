import type { Metadata } from 'next';

import { requireAdmin } from '@/server/admin/session';
import { env, signInMethods } from '@/server/config/env';
import { ping } from '@/server/db/mongo';
import { Badge, PageHeader, Panel, TableShell, Td, Th } from '@components/ui';

export const metadata: Metadata = { title: 'Settings' };

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * What this deployment is configured to do.
 *
 * **Read-only, and it must stay that way.** Everything here comes from the
 * process environment, which on Vercel is set in the project's settings and
 * takes effect on redeploy — a portal that appeared to edit it would be lying.
 *
 * ## Nothing on this page is a secret
 *
 * Every value is reduced to present/absent or to something already public. A
 * connection string, a signing key or an SMTP password must never reach a
 * browser, and the temptation to show "just the first few characters" of one is
 * how they end up in a screenshot. The rule this page follows is the one
 * `debugSummary()` follows: say whether it is set, never what it is.
 */
export default async function SettingsPage() {
  await requireAdmin();

  const dbUp = await ping();
  const methods = signInMethods();

  const rows: { label: string; value: React.ReactNode; hint?: string }[] = [
    {
      label: 'Environment',
      value: <Badge muted>{env.nodeEnv}</Badge>,
    },
    {
      label: 'Database',
      value: dbUp ? <Badge>Connected</Badge> : <Badge muted>Unreachable</Badge>,
      hint: `Database "${env.dbName}"`,
    },
    {
      label: 'Sign-in methods',
      value: (
        <span className="flex flex-wrap gap-1">
          {methods.map((method) => (
            <Badge key={method} muted>
              {method}
            </Badge>
          ))}
        </span>
      ),
      hint: 'A provider with no credentials is not offered to the app at all.',
    },
    {
      label: 'Email delivery',
      value: env.mailEnabled ? <Badge>SMTP configured</Badge> : <Badge muted>Not configured</Badge>,
      hint: env.mailEnabled
        ? undefined
        : 'Password resets cannot be delivered. In production the token is withheld rather than returned.',
    },
    {
      label: 'Phone sign-in',
      value: env.phoneSignInEnabled ? <Badge>Available</Badge> : <Badge muted>Switched off</Badge>,
      hint: env.phoneSignInEnabled
        ? undefined
        : 'No SMS provider, so the method is hidden rather than degraded.',
    },
    {
      label: 'Public API URL',
      value: env.publicApiUrl ? (
        <code className="font-mono text-xs">{env.publicApiUrl}</code>
      ) : (
        <Badge muted>Not set</Badge>
      ),
      hint: 'Where social providers send the browser back. Social sign-in is disabled without it.',
    },
    {
      label: 'App redirects',
      value: (
        <span className="flex flex-wrap gap-1">
          {env.oauthAppRedirects.map((uri) => (
            <code key={uri} className="font-mono text-xs">
              {uri}
            </code>
          ))}
        </span>
      ),
      hint: 'An exact-match allow-list. The last hop of a sign-in puts a one-time credential in a URL.',
    },
    {
      label: 'Browser origins',
      value:
        env.corsOrigins.length > 0 ? (
          <span className="flex flex-wrap gap-1">
            {env.corsOrigins.map((origin) => (
              <code key={origin} className="font-mono text-xs">
                {origin}
              </code>
            ))}
          </span>
        ) : (
          <Badge muted>Reflecting any origin</Badge>
        ),
      hint:
        env.corsOrigins.length > 0
          ? undefined
          : 'Set CORS_ORIGINS in production. Native mobile builds are unaffected — CORS is a browser mechanism.',
    },
    {
      label: 'Upload limits',
      value: (
        <span className="text-sm">
          {Math.round(env.maxLogoBytes / 1024)} KB images ·{' '}
          {Math.round(env.maxFontBytes / 1024)} KB fonts
        </span>
      ),
      hint: 'Below the platform’s 4.5 MB request cap, so an oversized file fails with an explanation.',
    },
  ];

  return (
    <>
      <PageHeader
        eyebrow="Deployment"
        title="Settings"
        description="How this deployment is configured. Read-only — these come from the environment and change on redeploy."
      />

      <Panel>
        <TableShell>
          <thead>
            <tr>
              <Th>Setting</Th>
              <Th>Value</Th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.label}>
                <Td className="w-48 align-top font-medium">{row.label}</Td>
                <Td>
                  {row.value}
                  {row.hint ? (
                    <p className="mt-1 text-xs text-ink-tertiary">{row.hint}</p>
                  ) : null}
                </Td>
              </tr>
            ))}
          </tbody>
        </TableShell>

        <p className="mt-5 text-xs text-ink-tertiary">
          No secret is shown on this page, in any form. Connection strings, signing keys
          and passwords are reported only as configured or absent.
        </p>
      </Panel>
    </>
  );
}
