import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import express from 'express';
import router from '../routes.js';

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
    '/api/v1/auth/oauth/apple/start',
    '/api/v1/auth/oauth/apple/callback',
  ]) {
    const response = await fetch(`${baseURL}${path}`, { method: 'POST' });
    assert.equal(response.status, 404);
    await response.text();
  }
});
