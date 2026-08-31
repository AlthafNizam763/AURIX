import { afterAll, beforeAll, describe, expect, it } from 'vitest';

import { missingRequired } from '@/server/config/env';
import { collections, close } from '@/server/db/mongo';
import { consume, clientAddress, type RateLimitRule } from '@/server/middleware/rate-limit';

/**
 * The rate limiter, against the real database.
 *
 * This is the piece of the migration with no counterpart to port — the Express
 * server used `express-rate-limit`'s in-memory store, which counts within one
 * process and therefore counts nothing useful across serverless instances. It
 * is also the piece where being wrong is a *security* regression rather than a
 * bug, so it is tested against Mongo rather than a mock: the property that
 * matters is that two callers sharing a bucket share a count, and a mock of the
 * database would be a mock of exactly the thing under test.
 */

const configured = missingRequired().length === 0;
const describeDb = configured ? describe : describe.skip;

/** A rule with a name unique to this run, so the suite cannot collide. */
function rule(overrides: Partial<RateLimitRule> = {}): RateLimitRule {
  return {
    name: `test_${Math.random().toString(36).slice(2, 10)}`,
    windowMs: 60_000,
    limit: 3,
    devLimit: 3,
    ...overrides,
  };
}

describe('identifying the caller', () => {
  it('takes the first entry of x-forwarded-for, which is the client', () => {
    // The rest are proxies. Keying on a proxy would limit the whole world as
    // one client, which turns a per-IP limit into a global outage under load.
    const request = new Request('https://example.com', {
      headers: { 'x-forwarded-for': '203.0.113.7, 70.41.3.18, 150.172.238.178' },
    });
    expect(clientAddress(request)).toBe('203.0.113.7');
  });

  it('falls back to x-real-ip', () => {
    const request = new Request('https://example.com', {
      headers: { 'x-real-ip': '203.0.113.9' },
    });
    expect(clientAddress(request)).toBe('203.0.113.9');
  });

  it('counts an unidentifiable caller rather than exempting one', () => {
    // Being anonymous must not be a way around the limit.
    expect(clientAddress(new Request('https://example.com'))).toBe('unknown');
  });
});

describeDb('counting, in the database', () => {
  const created: string[] = [];

  beforeAll(async () => {
    // Fail loudly rather than silently passing against nothing.
    const rateLimits = await collections.rateLimits();
    await rateLimits.countDocuments({}, { limit: 1 });
  });

  afterAll(async () => {
    if (created.length > 0) {
      const rateLimits = await collections.rateLimits();
      await rateLimits.deleteMany({ bucket: { $in: created } });
    }
    await close();
  });

  /** Remembers the bucket a rule will write, so it can be cleaned up. */
  function track(r: RateLimitRule, client: string) {
    created.push(`${r.name}:${client}:${Math.floor(Date.now() / r.windowMs)}`);
  }

  it('allows up to the limit and refuses the one after it', async () => {
    const r = rule({ limit: 3, devLimit: 3 });
    track(r, 'client-a');

    const first = await consume(r, 'client-a');
    expect(first.allowed).toBe(true);
    expect(first.remaining).toBe(2);

    expect((await consume(r, 'client-a')).allowed).toBe(true);
    expect((await consume(r, 'client-a')).allowed).toBe(true);

    const fourth = await consume(r, 'client-a');
    expect(fourth.allowed).toBe(false);
    expect(fourth.remaining).toBe(0);
  });

  it('counts each client separately', async () => {
    const r = rule({ limit: 1, devLimit: 1 });
    track(r, 'client-b');
    track(r, 'client-c');

    expect((await consume(r, 'client-b')).allowed).toBe(true);
    // A different caller has their own budget — otherwise one noisy client
    // would lock everybody else out.
    expect((await consume(r, 'client-c')).allowed).toBe(true);
    expect((await consume(r, 'client-b')).allowed).toBe(false);
  });

  it('counts concurrent requests exactly once each', async () => {
    // The property a read-then-write implementation loses: ten simultaneous
    // requests must consume ten, not "however many happened to observe the
    // same stale count". This is why the increment is one atomic upsert.
    const r = rule({ limit: 4, devLimit: 4 });
    track(r, 'client-d');

    const results = await Promise.all(
      Array.from({ length: 10 }, () => consume(r, 'client-d')),
    );

    expect(results.filter((x) => x.allowed)).toHaveLength(4);
    expect(results.filter((x) => !x.allowed)).toHaveLength(6);
  });

  it('shares one count across separate callers of the same bucket', async () => {
    // The whole point of moving the store into Mongo. Two serverless instances
    // are, from this function's perspective, exactly two callers — and they
    // must not each get their own allowance.
    const r = rule({ limit: 2, devLimit: 2 });
    track(r, 'client-e');

    const instanceOne = await consume(r, 'client-e');
    const instanceTwo = await consume(r, 'client-e');
    const instanceThree = await consume(r, 'client-e');

    expect(instanceOne.allowed).toBe(true);
    expect(instanceTwo.allowed).toBe(true);
    expect(instanceThree.allowed).toBe(false);
  });

  it('stamps an expiry so the window is swept without a cron', async () => {
    // Serverless has nowhere to run a sweeper, so the TTL index is the only
    // thing stopping this collection growing without bound.
    const r = rule({ windowMs: 60_000 });
    track(r, 'client-f');
    await consume(r, 'client-f');

    const rateLimits = await collections.rateLimits();
    const doc = await rateLimits.findOne({ bucket: created[created.length - 1] });

    expect(doc?.expiresAt).toBeInstanceOf(Date);
    expect(doc!.expiresAt.getTime()).toBeGreaterThan(Date.now());
    expect(doc!.expiresAt.getTime()).toBeLessThanOrEqual(Date.now() + 60_000);
  });
});
