import test from 'node:test';
import assert from 'node:assert/strict';
import jwt from 'jsonwebtoken';
import config from '../config/index.js';
import ClientSession from '../models/clientSession.model.js';
import { issueClientSession } from '../services/clientSession.js';

const objectId = (value) => ({ toString: () => value });

test('issued access tokens are short-lived and bound to a device session', async (t) => {
  const originalUpdateMany = ClientSession.updateMany;
  const originalCreate = ClientSession.create;
  t.after(() => {
    ClientSession.updateMany = originalUpdateMany;
    ClientSession.create = originalCreate;
  });

  let createdSession;
  ClientSession.updateMany = async () => ({ modifiedCount: 0 });
  ClientSession.create = async (session) => {
    createdSession = session;
    return { ...session, _id: objectId('session-1') };
  };

  const principal = { _id: objectId('principal-1') };
  const result = await issueClientSession(
    principal,
    'namespace',
    { id: 'device-1', name: 'Mac' }
  );
  const payload = jwt.verify(result.accessToken, config.clientJwt.secret);

  assert.equal(payload.sub, 'principal-1');
  assert.equal(payload.sid, 'session-1');
  assert.equal(payload.deviceId, 'device-1');
  assert.equal(payload.principalType, 'namespace');
  assert.ok(payload.exp - payload.iat <= 15 * 60);
  assert.equal(result.expiresIn, 15 * 60);
  assert.equal(typeof result.refreshToken, 'string');
  assert.ok(result.refreshToken.length >= 40);
  assert.notEqual(createdSession.tokenHash, result.refreshToken);
  assert.equal(createdSession.deviceId, 'device-1');
});
