import crypto from 'node:crypto';

import { env } from '../../config/env';

/**
 * Authenticated encryption for the provider tokens in `musicConnections`.
 *
 * ## Why this exists at all, when nothing else in the database is encrypted
 *
 * Every other secret AURIX stores is *hashed*: passwords, refresh tokens,
 * action tokens, OTP codes. Hashing works there because the server only ever
 * needs to answer "is the value you just showed me the one I stored?" — it
 * never needs the value back.
 *
 * A provider refresh token is the opposite. The server has to hand the literal
 * bytes to Spotify or Google months later, so it must be able to *read* it,
 * which rules hashing out. What is left is either plaintext or encryption at
 * rest, and plaintext is not defensible for a credential that grants access to
 * somebody's Spotify account and does not expire on its own.
 *
 * ## What this does and does not protect against
 *
 * It protects a **leaked database**: a stolen backup, a misconfigured Atlas
 * network rule, a dump in a support ticket. In every one of those the attacker
 * holds documents but not `MUSIC_TOKEN_KEY`, which lives in the process
 * environment.
 *
 * It does **not** protect against an attacker who is executing code in this
 * process — they can simply call [open]. That is not a gap this layer can close
 * and pretending otherwise would be worse than saying so.
 *
 * ## AES-256-GCM, not CBC
 *
 * GCM authenticates as well as encrypts, so a tampered ciphertext fails to
 * decrypt rather than decrypting to attacker-chosen bytes. For a value that is
 * about to be sent to Google as a credential, that property is the point.
 *
 * The stored form is `v1.<iv>.<tag>.<ciphertext>`, all base64url. The version
 * prefix is there so a future key rotation or algorithm change can be
 * recognised rather than guessed at — [open] refuses anything it does not
 * recognise instead of returning rubbish.
 */

const VERSION = 'v1';

/**
 * A 32-byte key derived from the configured secret.
 *
 * The environment value is an arbitrary-length string, and AES-256 needs
 * exactly 32 bytes, so it is run through SHA-256. This is a *key derivation
 * from a high-entropy secret*, not password hashing — `MUSIC_TOKEN_KEY` is a
 * random 48-byte value (or a derivation of `JWT_SECRET`, which is), so a slow
 * KDF would add cost without adding strength.
 *
 * Computed on each call rather than memoized at module load: `env` is read
 * lazily throughout this codebase so `next build` can run on a machine with no
 * production secrets, and a module-level `createHash` would defeat that.
 */
function key(): Buffer {
  const configured = env.musicTokenKey;
  if (!configured) {
    // Reached only when neither MUSIC_TOKEN_KEY nor JWT_SECRET is set, which
    // `assertConfigured` already refuses to serve on. Named explicitly anyway,
    // because silently encrypting with an empty key is the worst outcome here.
    throw new Error(
      'Provider tokens cannot be stored: set MUSIC_TOKEN_KEY (or JWT_SECRET) ' +
        'in the environment. See web/.env.example.',
    );
  }
  return crypto.createHash('sha256').update(configured).digest();
}

/** Encrypts a token for storage. */
export function seal(plaintext: string): string {
  const iv = crypto.randomBytes(12); // 96 bits, the size GCM is specified for
  const cipher = crypto.createCipheriv('aes-256-gcm', key(), iv);
  const body = Buffer.concat([cipher.update(plaintext, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [
    VERSION,
    iv.toString('base64url'),
    tag.toString('base64url'),
    body.toString('base64url'),
  ].join('.');
}

/**
 * Decrypts a stored token, or returns null.
 *
 * **Null rather than a throw**, and that choice is deliberate. The realistic
 * cause of a failure here is that `MUSIC_TOKEN_KEY` was rotated, which makes
 * every stored connection unreadable at once. The right response to that is
 * "your Spotify connection needs reconnecting" — an outcome the user can act on
 * — and not a 500 on the import screen. Callers turn null into
 * `provider_reconnect_required`.
 */
export function open(sealed: string | undefined | null): string | null {
  if (!sealed) return null;
  const parts = sealed.split('.');
  if (parts.length !== 4 || parts[0] !== VERSION) return null;

  try {
    const [, ivRaw, tagRaw, bodyRaw] = parts as [string, string, string, string];
    const decipher = crypto.createDecipheriv(
      'aes-256-gcm',
      key(),
      Buffer.from(ivRaw, 'base64url'),
    );
    decipher.setAuthTag(Buffer.from(tagRaw, 'base64url'));
    return Buffer.concat([
      decipher.update(Buffer.from(bodyRaw, 'base64url')),
      decipher.final(),
    ]).toString('utf8');
  } catch {
    // A wrong key, a truncated value, or a tampered one. All three mean the
    // same thing to the caller: this connection cannot be used.
    return null;
  }
}
