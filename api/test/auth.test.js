import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import express from 'express';
import router from '../routes.js';
import { accountPayload, oauthReturnURL } from '../controllers/auth.js';
import { ATTACHMENT_LIMIT_BYTES, NOTE_DATABASE_LIMIT_BYTES } from '../services/quota.js';

test('authentication surface excludes Apple login', async (t) => {
  const app = express();
  app.use(router);
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));

  const address = server.address();
  assert.notEqual(address, null);
  assert.equal(typeof address, 'object');
  const baseURL = `http://127.0.0.1:${address.port}`;

  const configResponse = await fetch(`${baseURL}/api/v1/auth/config`);
  assert.equal(configResponse.status, 200);
  const providers = await configResponse.json();
  assert.equal(Object.hasOwn(providers, 'apple'), false);
  assert.equal(providers.email.enabled, true);

  for (const path of [
    '/api/v1/auth/login',
    '/api/v1/auth/oauth/apple/start',
    '/api/v1/auth/oauth/apple/callback',
  ]) {
    const response = await fetch(`${baseURL}${path}`, { method: 'POST' });
    assert.equal(response.status, 404);
    await response.text();
  }
});

// A device is recorded, never rationed, and no device count is reported at
// all: the limit was removed so the web client could reach accounts that
// already have two Macs on them, and a browser mints a fresh device on every
// profile. What is left of `quota` is constants, so the account's plan is
// never looked up while building this payload.
test('account payload reports constant quotas and no device limit', () => {
  const principal = {
    _id: { toString: () => 'principal-1' },
    name: 'shared-wall',
    subscription: { planId: 'free', expiresAt: null },
    databaseSync: { version: 3, sizeBytes: 2048, updatedAt: null, url: null, sourceDeviceId: null },
  };
  const devices = [
    { deviceId: 'mac-1', name: 'Mac', lastSeenAt: new Date(0) },
    { deviceId: 'mac-2', name: 'Mac mini', lastSeenAt: new Date(0) },
    { deviceId: 'web-1', name: 'Chrome', lastSeenAt: new Date(0) },
  ];
  const payload = accountPayload(principal, 'namespace', {
    devices,
    usage: { noteDatabaseMB: 0.5, attachmentMB: 1.25 },
  });

  assert.deepEqual(Object.keys(payload.quota).sort(), [
    'attachmentLimitMB',
    'noteDatabaseLimitMB',
    'storageLimitMB',
  ]);
  assert.equal(payload.quota.noteDatabaseLimitMB, NOTE_DATABASE_LIMIT_BYTES / 1024 / 1024);
  assert.equal(payload.quota.attachmentLimitMB, ATTACHMENT_LIMIT_BYTES / 1024 / 1024);
  // A third device on what used to be a two-device plan is an ordinary state.
  assert.equal(payload.usage.devices, 3);
  assert.equal(payload.devices.length, 3);
});

// Google only ever redirects to the API's own callback, the same one the macOS
// app already uses. Which client started the round trip is remembered in the
// signed state, and decides only where the API bounces the browser afterwards
// — so adding the web client needed nothing registered at Google's end.
test('the OAuth round trip returns to whichever client began it', () => {
  assert.equal(oauthReturnURL('web'), 'http://localhost:5173/auth/google');
  assert.equal(oauthReturnURL('app'), 'ivy://oauth/google');
  // An unreadable state cannot name a client; the app scheme is the safe
  // default because a stray https redirect would be the worse failure.
  assert.equal(oauthReturnURL(undefined), 'ivy://oauth/google');
});
