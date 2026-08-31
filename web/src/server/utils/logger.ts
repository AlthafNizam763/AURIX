/**
 * Scoped, level-tagged logging — ported from `server/src/utils/logger.js`.
 *
 * Deliberately tiny and dependency-free. The one rule it enforces is that
 * errors print their stack in development and only their message in production,
 * so a stack trace containing file paths and query fragments never reaches a
 * shared log aggregator by accident.
 *
 * On Vercel these lines land in the function's log stream, which is exactly
 * where `console` output went before — no transport change was needed.
 */

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 } as const;

type Level = keyof typeof LEVELS;

const threshold: number =
  LEVELS[(process.env.LOG_LEVEL ?? '').toLowerCase() as Level] ??
  (process.env.NODE_ENV === 'production' ? LEVELS.info : LEVELS.debug);

function stamp(): string {
  return new Date().toISOString().slice(11, 23);
}

function write(level: Level, message: string, scope?: string, error?: unknown): void {
  if (LEVELS[level] < threshold) return;

  const tag = scope ? `[${scope}]` : '';
  const line = `${stamp()} ${level.toUpperCase().padEnd(5)} ${tag} ${message}`;
  const sink = level === 'error' || level === 'warn' ? console.error : console.log;
  sink(line);

  if (error !== undefined) {
    const detail =
      process.env.NODE_ENV === 'production'
        ? `        ${error instanceof Error ? error.message : String(error)}`
        : error;
    sink(detail);
  }
}

export const log = {
  debug: (message: string, scope?: string) => write('debug', message, scope),
  info: (message: string, scope?: string) => write('info', message, scope),
  warn: (message: string, scope?: string, error?: unknown) =>
    write('warn', message, scope, error),
  error: (message: string, scope?: string, error?: unknown) =>
    write('error', message, scope, error),
};
