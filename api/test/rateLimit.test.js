import test from 'node:test';
import assert from 'node:assert/strict';
import {
  MemoryRateLimitStore,
  consumeRateLimit,
} from '../services/rateLimit.js';

const day = 24 * 60 * 60 * 1000;

test('email verification address is limited to five sends per UTC window', async () => {
  const store = new MemoryRateLimitStore();
  const now = Date.UTC(2026, 7, 25, 12, 0, 0);
  const request = () => consumeRateLimit({
    scope: 'email-code-daily-address',
    identity: 'reader@example.com',
    limit: 5,
    windowMs: day,
    now,
    store,
  });

  for (let index = 0; index < 5; index += 1) {
    assert.equal((await request()).allowed, true);
  }
  const blocked = await request();
  assert.equal(blocked.allowed, false);
  assert.equal(blocked.remaining, 0);
  assert.equal(blocked.retryAfterSeconds, 12 * 60 * 60);

  const nextWindow = await consumeRateLimit({
    scope: 'email-code-daily-address',
    identity: 'reader@example.com',
    limit: 5,
    windowMs: day,
    now: now + day,
    store,
  });
  assert.equal(nextWindow.allowed, true);
});

test('rate-limit identities are isolated', async () => {
  const store = new MemoryRateLimitStore();
  const options = {
    scope: 'namespace-create-device',
    limit: 1,
    windowMs: day,
    now: Date.UTC(2026, 7, 25),
    store,
  };

  assert.equal((await consumeRateLimit({ ...options, identity: 'device-a' })).allowed, true);
  assert.equal((await consumeRateLimit({ ...options, identity: 'device-a' })).allowed, false);
  assert.equal((await consumeRateLimit({ ...options, identity: 'device-b' })).allowed, true);
});
