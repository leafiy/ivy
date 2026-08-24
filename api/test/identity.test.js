import test from 'node:test';
import assert from 'node:assert/strict';
import {
  isValidNamespace,
  namespaceKey,
  normalizeNamespace,
} from '../middleware/validate.js';
import { privateAccountHandle } from '../services/privateIdentity.js';
import User from '../models/user.model.js';

test('public namespaces accept complex, shareable names', () => {
  const name = '  朋友的  周末计划 ✨  ';
  assert.equal(normalizeNamespace(name), '朋友的 周末计划 ✨');
  assert.equal(namespaceKey(name), '朋友的 周末计划 ✨');
  assert.equal(isValidNamespace(name), true);
});

test('public namespace keys are case-insensitive and reject invisible controls', () => {
  assert.equal(namespaceKey('Ivy Friends'), namespaceKey('ivy friends'));
  assert.equal(isValidNamespace('ivy\u200bfriends'), false);
});

test('private handles are deterministic and provider-isolated', () => {
  const google = privateAccountHandle('google', 'subject-123');
  assert.equal(google, privateAccountHandle('google', 'subject-123'));
  assert.notEqual(google, privateAccountHandle('email', 'subject-123'));
  assert.match(google, /^private:google:[a-f0-9]{64}$/);
});

test('OAuth profile email is display-only and normalized', () => {
  const user = new User({
    username: privateAccountHandle('google', 'subject-123'),
    googleSub: 'subject-123',
    displayEmail: 'Leafiy.User@Example.COM',
  });
  assert.equal(user.displayEmail, 'leafiy.user@example.com');
  assert.equal(user.email, undefined);
});

