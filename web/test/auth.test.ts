import { afterEach, describe, expect, it, vi } from 'vitest';

import { signInMethods } from '@/server/config/env';
import { matchableEmail } from '@/server/services/identities';
import { deadEndPage, redirectWith } from '@/server/services/oauth/flow';
import { isApplePrivateRelay } from '@/server/services/oauth/providers';
import { isE164, maskEmail, maskPhone, normalisePhone } from '@/server/services/phone';
import { localProviders, publicUser } from '@/server/services/users';
import type { SocialProfile, UserDoc } from '@/server/db/documents';

/**
 * The parts of multi-method sign-in that can be decided without a database.
 *
 * Ported from `server/test/auth.test.js`. Every rule tested here is one where
 * getting it wrong produces a *security* failure rather than a visible bug — a
 * duplicate account, a linked identity that should have been challenged, an OTP
 * destination that two spellings of one number both miss. None of them need
 * MongoDB, because none of them are about storage; they are about what the
 * stored value is allowed to be.
 */

/** A user document with only the fields a given assertion cares about. */
const user = (fields: Partial<UserDoc>): UserDoc =>
  ({ uid: 'u1', name: '', avatarId: 'avatar_01', ...fields }) as UserDoc;

const profile = (fields: Partial<SocialProfile>): SocialProfile =>
  ({ subject: '123', email: '', emailVerified: false, name: '', avatarUrl: '', ...fields });

/**
 * Re-imports `phone` with one environment variable changed.
 *
 * The Express test mutated `env.defaultPhoneCountryCode` directly. The ported
 * `env` is `as const`, so it cannot be — which is the right trade: configuration
 * that a request can reach in and change is configuration that a bug can change
 * too. Restating it through the environment and reloading the module is what
 * the application itself does at startup.
 */
async function withCountryCode(code: string) {
  vi.stubEnv('DEFAULT_PHONE_COUNTRY_CODE', code);
  vi.resetModules();
  return import('@/server/services/phone');
}

describe('phone numbers', () => {
  afterEach(() => {
    vi.unstubAllEnvs();
    vi.resetModules();
  });

  it('canonicalises every spelling of one number to the same string', async () => {
    const { normalisePhone: normalise } = await withCountryCode('');
    const forms = [
      '+447700900123',
      '+44 7700 900123',
      '+44 (7700) 900-123',
      '0044 7700 900123',
      '+44–7700–900123',
    ];
    for (const form of forms) {
      expect(normalise(form), form).toBe('+447700900123');
    }
  });

  it('refuses a number with no country code when none is configured', async () => {
    const { normalisePhone: normalise } = await withCountryCode('');
    // Guessing a region here would mean sending somebody else's phone a
    // sign-in code, so refusing is the only safe answer.
    expect(() => normalise('07700900123')).toThrow(/phone number/i);
  });

  it('applies the configured country code and drops the trunk prefix', async () => {
    const { normalisePhone: normalise } = await withCountryCode('+44');
    expect(normalise('07700 900123')).toBe('+447700900123');
    expect(normalise('7700900123')).toBe('+447700900123');
  });

  it('rejects what is not a number at all', () => {
    for (const bad of ['', '   ', '+', '+0123456789', 'not a phone', '+12']) {
      expect(() => normalisePhone(bad), `accepted ${JSON.stringify(bad)}`).toThrow();
    }
  });

  it('rejects more than the fifteen digits E.164 allows', () => {
    expect(() => normalisePhone('+1234567890123456')).toThrow();
    expect(isE164('+123456789012345')).toBe(true);
  });

  it('masks enough to recognise and not enough to learn', () => {
    const masked = maskPhone('+447700900123');
    expect(masked).toMatch(/^\+44/);
    expect(masked).toMatch(/123$/);
    expect(masked.includes('7700900')).toBe(false);

    expect(maskEmail('alex@example.com').endsWith('@example.com')).toBe(true);
    expect(maskEmail('alex@example.com').includes('alex')).toBe(false);
    expect(maskEmail('not-an-address')).toBe('');
  });
});

describe('which provider emails may be matched on', () => {
  const base = profile({ email: 'alex@example.com', emailVerified: true });

  it('accepts a verified address, lowercased', () => {
    expect(matchableEmail({ ...base, email: 'Alex@Example.COM' })).toBe('alex@example.com');
  });

  it('refuses an unverified address', () => {
    // Anyone can type anyone's address into a GitHub or Google profile.
    // Matching on one would hand over the AURIX account that owns it.
    expect(matchableEmail({ ...base, emailVerified: false })).toBe('');
  });

  it('refuses an absent address', () => {
    expect(matchableEmail({ ...base, email: '' })).toBe('');
    expect(matchableEmail(undefined)).toBe('');
  });

  it("refuses Apple's private relay, by flag or by domain", () => {
    expect(matchableEmail({ ...base, email: 'abc123@privaterelay.appleid.com' })).toBe('');
    expect(matchableEmail({ ...base, isPrivateRelay: true })).toBe('');
  });

  it('recognises a relay address whatever its case', () => {
    expect(isApplePrivateRelay('ABC@PrivateRelay.AppleID.com')).toBe(true);
    expect(isApplePrivateRelay('alex@example.com')).toBe(false);
    expect(isApplePrivateRelay(null)).toBe(false);
  });
});

describe('the account shape the app receives', () => {
  it('reports the methods that live on the user document', () => {
    expect(localProviders(user({ passwordHash: 'x', phone: '+44770' }))).toEqual([
      'password',
      'phone',
    ]);
    expect(localProviders(user({ passwordHash: '' }))).toEqual([]);
    expect(localProviders(user({}))).toEqual([]);
  });

  it('never serialises the password hash', () => {
    const view = publicUser(user({ email: 'a@b.com', passwordHash: 'SECRET-HASH' }));
    expect(JSON.stringify(view).includes('SECRET-HASH')).toBe(false);
    expect(view && 'passwordHash' in view).toBe(false);
  });

  it('carries the fields the multi-method login screen needs', () => {
    const view = publicUser(
      user({ email: 'a@b.com', phone: '+447700900123', emailIsPrivateRelay: true }),
      { providers: ['google', 'password'] },
    );
    expect(view?.phone).toBe('+447700900123');
    expect(view?.emailIsPrivateRelay).toBe(true);
    expect(view?.providers).toEqual(['google', 'password']);
  });

  it('defaults every optional flag rather than emitting undefined', () => {
    const view = publicUser(user({}));
    expect(view?.email).toBe('');
    expect(view?.phone).toBe('');
    expect(view?.emailVerified).toBe(false);
    expect(view?.phoneVerified).toBe(false);
    expect(view?.emailIsPrivateRelay).toBe(false);
    expect(view?.providers).toEqual([]);
  });
});

describe('what the deployment advertises', () => {
  it('always offers a password', () => {
    // The one method that needs nothing but the database.
    expect(signInMethods()).toContain('password');
  });

  it('offers no provider whose credentials are absent', async () => {
    // A login screen must not draw four buttons that lead to a consent screen
    // nobody registered.
    const { env } = await import('@/server/config/env');
    for (const id of ['google', 'apple', 'facebook', 'github']) {
      if (signInMethods().includes(id)) {
        expect(env.publicApiUrl.length, `${id} offered with no PUBLIC_API_URL`).toBeGreaterThan(0);
      }
    }
  });

  it('offers phone only when a code can actually be delivered', async () => {
    // The whole point of gating this: without a transport, "Phone" is a button
    // that mints a credential and drops it. `POST /auth/phone/start` refuses
    // for the same reason, so the two cannot disagree.
    const { env } = await import('@/server/config/env');
    expect(signInMethods().includes('phone')).toBe(env.phoneSignInEnabled);
  });
});

describe('a one-time code never leaves the process', () => {
  it('is not logged when there is no SMS transport', async () => {
    // The regression this guards is specific: an earlier version printed the
    // whole message — code included — when Twilio was unconfigured. Anyone who
    // could read the console could then sign in as any number they could type.
    //
    // The Express suite also had a case for `OTP_DEV_DELIVERY=file`. That mode
    // no longer exists — serverless has no durable filesystem to write to — so
    // the case is gone with it, and this is now the only path.
    const { env } = await import('@/server/config/env');
    if (env.smsEnabled) {
      // A configured deployment would really send one. Not this suite's job.
      return;
    }

    const lines: string[] = [];
    const { log } = await import('@/server/utils/logger');
    const original = { warn: log.warn, info: log.info, error: log.error };
    for (const level of ['warn', 'info', 'error'] as const) {
      log[level] = (message: string) => void lines.push(String(message));
    }

    try {
      const { deliverSignInCode } = await import('@/server/services/sms');
      const delivered = await deliverSignInCode('+447700900123', '654321');

      // No transport: nothing was delivered, and the caller is told so rather
      // than being left to assume an SMS is on its way.
      expect(delivered).toBe(false);
      expect(lines.length, 'expected the absent transport to be reported').toBeGreaterThan(0);
      for (const line of lines) {
        expect(line.includes('654321'), line).toBe(false);
      }
    } finally {
      Object.assign(log, original);
    }
  });
});

describe('the browser round trip', () => {
  it('appends the grant to a custom scheme and to an http redirect alike', () => {
    expect(redirectWith('aurix://login-callback', { code: 'abc', state: 'xyz' })).toBe(
      'aurix://login-callback?code=abc&state=xyz',
    );
    expect(redirectWith('https://app.example.com/auth.html?x=1', { code: 'a b' })).toBe(
      'https://app.example.com/auth.html?x=1&code=a+b',
    );
  });

  it('escapes the message on the dead-end page', () => {
    // The message can carry a provider's own error text, which is attacker
    // influenced in the general case.
    const page = deadEndPage('<script>alert(1)</script> & more');
    expect(page.includes('<script>')).toBe(false);
    expect(page.includes('&lt;script&gt;')).toBe(true);
    expect(page.includes('&amp; more')).toBe(true);
  });
});
