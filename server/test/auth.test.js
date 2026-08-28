import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import { isE164, maskEmail, maskPhone, normalisePhone } from '../src/services/phone.js';
import { matchableEmail } from '../src/services/identities.js';
import { localProviders, publicUser } from '../src/services/users.js';
import { deadEndPage, redirectWith } from '../src/services/oauth/flow.js';
import { isApplePrivateRelay } from '../src/services/oauth/providers.js';
import { env, signInMethods } from '../src/config/env.js';
import { deliverSignInCode } from '../src/services/sms.js';
import { log } from '../src/utils/logger.js';

/**
 * The parts of multi-method sign-in that can be decided without a database.
 *
 * Every rule tested here is one where getting it wrong produces a *security*
 * failure rather than a visible bug — a duplicate account, a linked identity
 * that should have been challenged, an OTP destination that two spellings of
 * one number both miss. None of them need MongoDB, because none of them are
 * about storage; they are about what the stored value is allowed to be.
 */

describe('phone numbers', () => {
  const original = env.defaultPhoneCountryCode;
  after(() => {
    env.defaultPhoneCountryCode = original;
  });

  it('canonicalises every spelling of one number to the same string', () => {
    const forms = [
      '+447700900123',
      '+44 7700 900123',
      '+44 (7700) 900-123',
      '0044 7700 900123',
      '+44\u20137700\u2013900123',
    ];
    for (const form of forms) {
      assert.equal(normalisePhone(form), '+447700900123', form);
    }
  });

  it('refuses a number with no country code when none is configured', () => {
    env.defaultPhoneCountryCode = '';
    // Guessing a region here would mean sending somebody else's phone a
    // sign-in code, so refusing is the only safe answer.
    assert.throws(() => normalisePhone('07700900123'), /phone number/i);
  });

  it('applies the configured country code and drops the trunk prefix', () => {
    env.defaultPhoneCountryCode = '+44';
    assert.equal(normalisePhone('07700 900123'), '+447700900123');
    assert.equal(normalisePhone('7700900123'), '+447700900123');
  });

  it('rejects what is not a number at all', () => {
    for (const bad of ['', '   ', '+', '+0123456789', 'not a phone', '+12']) {
      assert.throws(() => normalisePhone(bad), Error, `accepted ${JSON.stringify(bad)}`);
    }
  });

  it('rejects more than the fifteen digits E.164 allows', () => {
    assert.throws(() => normalisePhone('+1234567890123456'));
    assert.equal(isE164('+123456789012345'), true);
  });

  it('masks enough to recognise and not enough to learn', () => {
    const masked = maskPhone('+447700900123');
    assert.match(masked, /^\+44/);
    assert.match(masked, /123$/);
    assert.equal(masked.includes('7700900'), false);

    assert.equal(maskEmail('alex@example.com').endsWith('@example.com'), true);
    assert.equal(maskEmail('alex@example.com').includes('alex'), false);
    assert.equal(maskEmail('not-an-address'), '');
  });
});

describe('which provider emails may be matched on', () => {
  const base = { subject: '123', email: 'alex@example.com', emailVerified: true };

  it('accepts a verified address, lowercased', () => {
    assert.equal(matchableEmail({ ...base, email: 'Alex@Example.COM' }), 'alex@example.com');
  });

  it('refuses an unverified address', () => {
    // Anyone can type anyone's address into a GitHub or Google profile.
    // Matching on one would hand over the AURIX account that owns it.
    assert.equal(matchableEmail({ ...base, emailVerified: false }), '');
  });

  it('refuses an absent address', () => {
    assert.equal(matchableEmail({ subject: '1', email: '', emailVerified: true }), '');
    assert.equal(matchableEmail({ subject: '1' }), '');
  });

  it("refuses Apple's private relay, by flag or by domain", () => {
    assert.equal(
      matchableEmail({ ...base, email: 'abc123@privaterelay.appleid.com' }),
      '',
    );
    assert.equal(matchableEmail({ ...base, isPrivateRelay: true }), '');
  });

  it('recognises a relay address whatever its case', () => {
    assert.equal(isApplePrivateRelay('ABC@PrivateRelay.AppleID.com'), true);
    assert.equal(isApplePrivateRelay('alex@example.com'), false);
    assert.equal(isApplePrivateRelay(null), false);
  });
});

describe('the account shape the app receives', () => {
  it('reports the methods that live on the user document', () => {
    assert.deepEqual(localProviders({ passwordHash: 'x', phone: '+44770' }), [
      'password',
      'phone',
    ]);
    assert.deepEqual(localProviders({ passwordHash: '' }), []);
    assert.deepEqual(localProviders({}), []);
  });

  it('never serialises the password hash', () => {
    const view = publicUser({ uid: 'u1', email: 'a@b.com', passwordHash: 'SECRET-HASH' });
    assert.equal(JSON.stringify(view).includes('SECRET-HASH'), false);
    assert.equal('passwordHash' in view, false);
  });

  it('carries the fields the multi-method login screen needs', () => {
    const view = publicUser(
      { uid: 'u1', email: 'a@b.com', phone: '+447700900123', emailIsPrivateRelay: true },
      { providers: ['google', 'password'] },
    );
    assert.equal(view.phone, '+447700900123');
    assert.equal(view.emailIsPrivateRelay, true);
    assert.deepEqual(view.providers, ['google', 'password']);
  });

  it('defaults every optional flag rather than emitting undefined', () => {
    const view = publicUser({ uid: 'u1' });
    assert.equal(view.email, '');
    assert.equal(view.phone, '');
    assert.equal(view.emailVerified, false);
    assert.equal(view.phoneVerified, false);
    assert.equal(view.emailIsPrivateRelay, false);
    assert.deepEqual(view.providers, []);
  });
});

describe('what the deployment advertises', () => {
  it('always offers a password', () => {
    // The one method that needs nothing but the database.
    assert.equal(signInMethods().includes('password'), true);
  });

  it('offers no provider whose credentials are absent', () => {
    // This repository ships without OAuth credentials, so the login screen
    // must not draw four buttons that lead to a consent screen nobody
    // registered.
    for (const id of ['google', 'apple', 'facebook', 'github']) {
      if (signInMethods().includes(id)) {
        assert.ok(env.publicApiUrl.length > 0, `${id} offered with no PUBLIC_API_URL`);
      }
    }
  });

  it('offers phone only when a code can actually be delivered', () => {
    // The whole point of gating this: without a transport, "Phone" is a button
    // that mints a credential and drops it. `POST /auth/phone/start` refuses
    // for the same reason, so the two cannot disagree.
    assert.equal(signInMethods().includes('phone'), env.phoneSignInEnabled);
  });

  it('never treats the dev sink as a production delivery route', () => {
    // `OTP_DEV_DELIVERY` is read through `isProduction` in config/env.js, so
    // there is no route, flag or request that can opt back into it.
    if (env.isProduction) assert.equal(env.otp.devDelivery, '');
  });
});

describe('a one-time code never leaves the process', () => {
  /// Captures everything the logger emits while `body` runs.
  async function capturingLogs(body) {
    const lines = [];
    const original = { warn: log.warn, info: log.info, error: log.error };
    for (const level of ['warn', 'info', 'error']) {
      log[level] = (message) => lines.push(String(message));
    }
    try {
      return { result: await body(), lines };
    } finally {
      Object.assign(log, original);
    }
  }

  // The dev sink is read from the ambient `.env`, and a developer who has
  // switched it on must not turn these into failures — the property under test
  // is about what `deliverSignInCode` does, not about how this machine is
  // configured. So each case sets the mode it is testing and restores it.
  const originalDelivery = env.otp.devDelivery;
  after(() => {
    env.otp.devDelivery = originalDelivery;
  });

  it('is not logged when there is no SMS transport', async () => {
    // The regression this guards is specific: an earlier version printed the
    // whole message — code included — when Twilio was unconfigured. Anyone who
    // could read the console could then sign in as any number they could type.
    env.otp.devDelivery = '';

    const { result: delivered, lines } = await capturingLogs(() =>
      deliverSignInCode('+447700900123', '654321'),
    );

    // No transport and no dev sink: nothing was delivered, and the caller is
    // told so rather than being left to assume an SMS is on its way.
    assert.equal(delivered, false);
    assert.ok(lines.length > 0, 'expected the absent transport to be reported');
    for (const line of lines) {
      assert.equal(line.includes('654321'), false, line);
    }
  });

  it('is not logged when the development file sink is in use', async () => {
    // `OTP_DEV_DELIVERY=file` is the supported way to exercise phone sign-in
    // without a Twilio account, and it is the configuration a developer is
    // most likely to be running. The file is the *one* place the code may
    // appear; the console still must not carry it, because a shared terminal
    // or a CI log is exactly what the sink exists to avoid.
    env.otp.devDelivery = 'file';

    const { result: delivered, lines } = await capturingLogs(() =>
      deliverSignInCode('+447700900124', '112233'),
    );

    assert.equal(delivered, true);
    assert.ok(lines.length > 0, 'expected the dev sink to announce itself');
    for (const line of lines) {
      assert.equal(line.includes('112233'), false, line);
    }
  });
});

describe('the browser round trip', () => {
  it('appends the grant to a custom scheme and to an http redirect alike', () => {
    assert.equal(
      redirectWith('aurix://login-callback', { code: 'abc', state: 'xyz' }),
      'aurix://login-callback?code=abc&state=xyz',
    );
    assert.equal(
      redirectWith('https://app.example.com/auth.html?x=1', { code: 'a b' }),
      'https://app.example.com/auth.html?x=1&code=a+b',
    );
  });

  it('escapes the message on the dead-end page', () => {
    // The message can carry a provider's own error text, which is attacker
    // influenced in the general case.
    const page = deadEndPage('<script>alert(1)</script> & more');
    assert.equal(page.includes('<script>'), false);
    assert.equal(page.includes('&lt;script&gt;'), true);
    assert.equal(page.includes('&amp; more'), true);
  });
});
