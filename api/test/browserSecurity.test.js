import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import express from 'express';
import browserCors from '../middleware/cors.js';
import {
  requireWebCsrf,
  setBrowserSessionCookies,
} from '../middleware/browserSession.js';

const listen = async (app, t) => {
  const server = app.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
};

test('browser CORS accepts configured origins and credentials', async (t) => {
  const app = express();
  app.use(browserCors);
  app.get('/ok', (_req, res) => res.json({ ok: true }));
  app.use((error, _req, res, _next) => res.status(error.statusCode || 500).json({ code: error.code }));
  const baseURL = await listen(app, t);

  const allowed = await fetch(`${baseURL}/ok`, {
    headers: { origin: 'http://localhost:3000' },
  });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'http://localhost:3000');
  assert.equal(allowed.headers.get('access-control-allow-credentials'), 'true');

  const denied = await fetch(`${baseURL}/ok`, {
    headers: { origin: 'https://attacker.example' },
  });
  assert.equal(denied.status, 403);
});

test('web refresh requires matching double-submit CSRF token', async (t) => {
  const app = express();
  app.use(express.json());
  app.post('/session', (_req, res) => {
    const csrfToken = setBrowserSessionCookies(res, 'refresh-secret');
    res.json({ csrfToken });
  });
  app.post('/refresh', requireWebCsrf, (_req, res) => res.json({ refreshed: true }));
  app.use((error, _req, res, _next) => res.status(error.statusCode || 500).json({ code: error.code }));
  const baseURL = await listen(app, t);

  const session = await fetch(`${baseURL}/session`, { method: 'POST' });
  const body = await session.json();
  const setCookies = session.headers.getSetCookie();
  assert.equal(setCookies.some((value) => value.startsWith('ivy_refresh=') && value.includes('HttpOnly')), true);
  assert.equal(setCookies.some((value) => value.startsWith('ivy_csrf=') && !value.includes('HttpOnly')), true);
  const cookieHeader = setCookies.map((value) => value.split(';', 1)[0]).join('; ');

  const rejected = await fetch(`${baseURL}/refresh`, {
    method: 'POST',
    headers: { cookie: cookieHeader, 'x-ivy-client': 'web' },
  });
  assert.equal(rejected.status, 403);

  const accepted = await fetch(`${baseURL}/refresh`, {
    method: 'POST',
    headers: {
      cookie: cookieHeader,
      'x-csrf-token': body.csrfToken,
      'x-ivy-client': 'web',
    },
  });
  assert.equal(accepted.status, 200);
});
