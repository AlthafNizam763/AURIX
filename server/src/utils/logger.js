/**
 * Scoped, level-tagged logging — the server counterpart of `AppLogger`.
 *
 * Deliberately tiny and dependency-free. The one rule it enforces is that
 * errors print their stack in development and only their message in
 * production, so a stack trace containing file paths and query fragments never
 * reaches a shared log aggregator by accident.
 */
const LEVELS = { debug: 10, info: 20, warn: 30, error: 40 };

const threshold =
  LEVELS[(process.env.LOG_LEVEL ?? '').toLowerCase()] ??
  (process.env.NODE_ENV === 'production' ? LEVELS.info : LEVELS.debug);

function stamp() {
  return new Date().toISOString().slice(11, 23);
}

function write(level, message, scope, error) {
  if (LEVELS[level] < threshold) return;
  const tag = scope ? `[${scope}]` : '';
  const line = `${stamp()} ${level.toUpperCase().padEnd(5)} ${tag} ${message}`;
  const sink = level === 'error' || level === 'warn' ? console.error : console.log;
  sink(line);
  if (error) {
    sink(process.env.NODE_ENV === 'production' ? `        ${error.message}` : error);
  }
}

export const log = {
  debug: (message, scope) => write('debug', message, scope),
  info: (message, scope) => write('info', message, scope),
  warn: (message, scope, error) => write('warn', message, scope, error),
  error: (message, scope, error) => write('error', message, scope, error),
};
