import { afterAll, describe, expect, it } from 'vitest';

import { missingRequired } from '@/server/config/env';
import { close, collections } from '@/server/db/mongo';
import { OTP_PURPOSE, clearOtp, issueOtp, verifyOtp } from '@/server/services/otp';
import {
  ACTION,
  consumeActionToken,
  issueAccessToken,
  issueActionToken,
  issueRefreshToken,
  revokeAllRefreshTokens,
  rotateRefreshToken,
  verifyAccessToken,
} from '@/server/services/tokens';
import { createUser, userByEmail, verifyPassword } from '@/server/services/users';
import type { UserDoc } from '@/server/db/documents';

/**
 * Identity, against the real database.
 *
 * Everything here is a rule whose failure is silent rather than loud: a refresh
 * token that can be replayed still signs people in, an OTP that ignores its
 * attempt cap still verifies, and an account created twice still returns a
 * user. None of them would show up as a broken screen — which is exactly why
 * they are worth asserting.
 */

const configured = missingRequired().length === 0;
const describeDb = configured ? describe : describe.skip;

/** Namespaced so a run cannot touch a real account, and can clean up after itself. */
const stamp = () => `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
const testEmail = () => `aurix-test-${stamp()}@example.invalid`;

describeDb('identity', () => {
  const createdUids: string[] = [];
  const createdDestinations: string[] = [];

  afterAll(async () => {
    if (createdUids.length > 0) {
      const users = await collections.users();
      const refreshTokens = await collections.refreshTokens();
      const actionTokens = await collections.actionTokens();
      await Promise.all([
        users.deleteMany({ uid: { $in: createdUids } }),
        refreshTokens.deleteMany({ uid: { $in: createdUids } }),
        actionTokens.deleteMany({ uid: { $in: createdUids } }),
      ]);
    }
    if (createdDestinations.length > 0) {
      const otpCodes = await collections.otpCodes();
      const otpSends = await collections.otpSends();
      await Promise.all([
        otpCodes.deleteMany({ destination: { $in: createdDestinations } }),
        otpSends.deleteMany({ destination: { $in: createdDestinations } }),
      ]);
    }
    await close();
  });

  async function makeUser(overrides: Parameters<typeof createUser>[0] = {}): Promise<UserDoc> {
    const created = await createUser({ email: testEmail(), name: 'Test', ...overrides });
    createdUids.push(created.uid);
    return created;
  }

  // -------------------------------------------------------------------------

  describe('accounts', () => {
    it('stores a bcrypt hash and never the password', async () => {
      const created = await makeUser({ password: 'correct horse battery' });
      expect(created.passwordHash).toBeTruthy();
      expect(created.passwordHash).not.toContain('correct horse');
      expect(await verifyPassword('correct horse battery', created.passwordHash)).toBe(true);
      expect(await verifyPassword('wrong', created.passwordHash)).toBe(false);
    });

    it('answers false rather than throwing for an account with no password', async () => {
      // The login route depends on this: it calls `verifyPassword` with
      // `user?.passwordHash ?? ''` for an account that does not exist, so that
      // bcrypt runs either way and response timing does not disclose which
      // addresses are registered.
      expect(await verifyPassword('anything', undefined)).toBe(false);
      expect(await verifyPassword('anything', '')).toBe(false);
    });

    it('omits an absent email rather than storing an empty string', async () => {
      // The unique index on `email` is sparse: it skips documents missing the
      // field, but indexes `''` like any other value. Storing an empty string
      // would let exactly one phone-only account exist and reject the second
      // with a duplicate key.
      const created = await makeUser({ email: '', phone: `+9999${Date.now() % 10_000_000}` });
      const users = await collections.users();
      const stored = await users.findOne({ uid: created.uid });
      expect(stored).not.toBeNull();
      expect('email' in stored!).toBe(false);
    });

    it('refuses a second account for the same address', async () => {
      const email = testEmail();
      const first = await createUser({ email, name: 'First' });
      createdUids.push(first.uid);
      // The unique index is the check, not a prior read — two devices
      // registering at the same instant both pass a read and only one passes
      // the index.
      await expect(createUser({ email, name: 'Second' })).rejects.toMatchObject({
        code: 'email_in_use',
        status: 409,
      });
    });

    it('matches an address case-insensitively', async () => {
      const created = await makeUser();
      const found = await userByEmail(created.email!.toUpperCase());
      expect(found?.uid).toBe(created.uid);
    });

    it('never matches an empty address against a phone-only account', async () => {
      // `findOne({ email: null })` matches every document where the field is
      // absent, so an unguarded lookup with an empty address would hand back a
      // stranger.
      expect(await userByEmail('')).toBeNull();
      expect(await userByEmail(undefined)).toBeNull();
    });
  });

  // -------------------------------------------------------------------------

  describe('tokens', () => {
    it('round-trips an access token and refuses a refresh token in its place', async () => {
      const created = await makeUser();
      const access = issueAccessToken(created);
      const claims = verifyAccessToken(access);
      expect(claims.sub).toBe(created.uid);
      expect(claims.admin).toBe(false);

      const { token: refresh } = await issueRefreshToken(created.uid);
      // Different secrets, so a refresh token cannot be presented where an
      // access token is expected even though both are JWTs.
      expect(() => verifyAccessToken(refresh)).toThrow();
    });

    it('rotates a refresh token and detects the replay', async () => {
      const created = await makeUser();
      const { token } = await issueRefreshToken(created.uid, { device: 'test' });

      expect(await rotateRefreshToken(token)).toBe(created.uid);
      // The delete *is* the check: a token used twice fails the second time,
      // because the first use removed it.
      await expect(rotateRefreshToken(token)).rejects.toMatchObject({
        code: 'unauthenticated',
      });
    });

    it('ends every session at once', async () => {
      const created = await makeUser();
      const a = await issueRefreshToken(created.uid, { device: 'phone' });
      const b = await issueRefreshToken(created.uid, { device: 'tablet' });

      await revokeAllRefreshTokens(created.uid);

      // What a password change relies on: the other device is signed out too.
      await expect(rotateRefreshToken(a.token)).rejects.toThrow();
      await expect(rotateRefreshToken(b.token)).rejects.toThrow();
    });

    it('spends an action token exactly once', async () => {
      const created = await makeUser();
      const { token } = await issueActionToken(created.uid, ACTION.resetPassword);

      expect(await consumeActionToken(token, ACTION.resetPassword)).toBe(created.uid);
      await expect(consumeActionToken(token, ACTION.resetPassword)).rejects.toThrow();
    });

    it('will not spend a reset token as a verification token', async () => {
      const created = await makeUser();
      const { token } = await issueActionToken(created.uid, ACTION.resetPassword);
      await expect(consumeActionToken(token, ACTION.verifyEmail)).rejects.toThrow();
    });

    it('invalidates the previous link when a second is requested', async () => {
      // A reset link forwarded or leaked earlier must stop working.
      const created = await makeUser();
      const first = await issueActionToken(created.uid, ACTION.resetPassword);
      await issueActionToken(created.uid, ACTION.resetPassword);

      await expect(consumeActionToken(first.token, ACTION.resetPassword)).rejects.toThrow();
    });
  });

  // -------------------------------------------------------------------------

  describe('one-time codes', () => {
    /** A destination unique to this run, with the cooldown out of the way. */
    async function freshDestination(): Promise<string> {
      const destination = `+99${Date.now() % 100_000_000_0}`;
      createdDestinations.push(destination);
      await clearOtp({ destination, purpose: OTP_PURPOSE.signIn });
      return destination;
    }

    it('verifies the right code and consumes it', async () => {
      const destination = await freshDestination();
      const { code } = await issueOtp({ destination, purpose: OTP_PURPOSE.signIn });

      expect(await verifyOtp({ destination, purpose: OTP_PURPOSE.signIn, code })).toBe(true);
      // Consumed: the same code cannot be replayed.
      await expect(
        verifyOtp({ destination, purpose: OTP_PURPOSE.signIn, code }),
      ).rejects.toThrow();
    });

    it('stores only a hash, never the code', async () => {
      const destination = await freshDestination();
      const { code } = await issueOtp({ destination, purpose: OTP_PURPOSE.signIn });

      const otpCodes = await collections.otpCodes();
      const stored = await otpCodes.findOne({ destination, purpose: OTP_PURPOSE.signIn });
      expect(JSON.stringify(stored)).not.toContain(code);
    });

    it('rejects a wrong code and spends an attempt', async () => {
      const destination = await freshDestination();
      const { code } = await issueOtp({ destination, purpose: OTP_PURPOSE.signIn });
      const wrong = code === '000000' ? '111111' : '000000';

      await expect(
        verifyOtp({ destination, purpose: OTP_PURPOSE.signIn, code: wrong }),
      ).rejects.toMatchObject({ code: 'invalid_code' });

      const otpCodes = await collections.otpCodes();
      const stored = await otpCodes.findOne({ destination, purpose: OTP_PURPOSE.signIn });
      expect(stored?.attempts).toBe(1);
    });

    it('reports no live code as a wrong code', async () => {
      // Distinguishing "nothing was sent" from "wrong code" tells an attacker
      // which numbers have a sign-in in progress — the same enumeration leak
      // the login route avoids.
      const destination = await freshDestination();
      await expect(
        verifyOtp({ destination, purpose: OTP_PURPOSE.signIn, code: '123456' }),
      ).rejects.toMatchObject({ code: 'invalid_code' });
    });

    it('will not redeem a sign-in code against a link', async () => {
      // The purpose is part of the key, so a code issued for one thing cannot
      // authorise another.
      const destination = await freshDestination();
      const { code } = await issueOtp({ destination, purpose: OTP_PURPOSE.signIn });

      await expect(
        verifyOtp({ destination, purpose: OTP_PURPOSE.linkAccount, code }),
      ).rejects.toThrow();
    });

    it('enforces the resend cooldown', async () => {
      const destination = await freshDestination();
      await issueOtp({ destination, purpose: OTP_PURPOSE.signIn });
      // What makes the app's "Resend in 30s" honest rather than decorative.
      await expect(
        issueOtp({ destination, purpose: OTP_PURPOSE.signIn }),
      ).rejects.toMatchObject({ code: 'rate_limited' });
    });
  });
});
