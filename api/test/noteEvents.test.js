import test from 'node:test';
import assert from 'node:assert/strict';
import { publish, roomCount, subscribe } from '../services/noteEvents.js';

const principal = (id, modelName = 'Namespace') => ({
  _id: { toString: () => id },
  constructor: { modelName },
});

const collect = () => {
  const seen = [];
  return [seen, (payload) => seen.push(JSON.parse(payload))];
};

test('an announcement reaches every listener on that account and nobody else', () => {
  const [mine, sendMine] = collect();
  const [otherTab, sendOtherTab] = collect();
  const [stranger, sendStranger] = collect();

  const stop = [
    subscribe(principal('account-1'), sendMine),
    subscribe(principal('account-1'), sendOtherTab),
    subscribe(principal('account-2'), sendStranger),
  ];

  publish({ toString: () => 'account-1' }, 'Namespace', { version: 7, noteIds: ['n1'], source: 'web' });

  assert.deepEqual(mine, [{ version: 7, noteIds: ['n1'], source: 'web' }]);
  assert.deepEqual(otherTab, mine);
  assert.deepEqual(stranger, []);
  for (const unsubscribe of stop) unsubscribe();
});

test('accounts are keyed by collection too, so two ids can never collide', () => {
  // A namespace and a user could in principle carry the same id string; they
  // are different accounts and must not hear each other.
  const [namespaceSeen, sendNamespace] = collect();
  const [userSeen, sendUser] = collect();
  const stop = [
    subscribe(principal('same-id', 'Namespace'), sendNamespace),
    subscribe(principal('same-id', 'User'), sendUser),
  ];

  publish({ toString: () => 'same-id' }, 'User', { version: 2 });

  assert.equal(namespaceSeen.length, 0);
  assert.equal(userSeen.length, 1);
  for (const unsubscribe of stop) unsubscribe();
});

test('a broken stream does not stop the announcement reaching the others', () => {
  const [seen, send] = collect();
  const stop = [
    subscribe(principal('account-3'), () => { throw new Error('socket already gone'); }),
    subscribe(principal('account-3'), send),
  ];

  assert.doesNotThrow(() => publish({ toString: () => 'account-3' }, 'Namespace', { version: 1 }));
  assert.equal(seen.length, 1);
  for (const unsubscribe of stop) unsubscribe();
});

test('unsubscribing the last listener drops the room rather than leaking it', () => {
  const before = roomCount();
  const unsubscribeA = subscribe(principal('account-4'), () => {});
  const unsubscribeB = subscribe(principal('account-4'), () => {});
  assert.equal(roomCount(), before + 1);

  unsubscribeA();
  assert.equal(roomCount(), before + 1, 'one listener left, the room stays');
  unsubscribeB();
  assert.equal(roomCount(), before, 'nobody left, the room goes');
  // Unsubscribing twice is harmless — close handlers fire more than once.
  assert.doesNotThrow(unsubscribeB);
});

test('publishing to an account nobody is watching costs nothing', () => {
  assert.doesNotThrow(() => publish({ toString: () => 'nobody' }, 'Namespace', { version: 1 }));
});

test('the payload carries the version and ids, never the notes', () => {
  const [seen, send] = collect();
  const stop = subscribe(principal('account-5'), send);

  publish({ toString: () => 'account-5' }, 'Namespace', { version: 9, noteIds: ['a', 'b'] });

  // A note's text must never be broadcast to a tab that is not showing it;
  // listeners refetch what they care about.
  assert.deepEqual(Object.keys(seen[0]).sort(), ['noteIds', 'source', 'version']);
  assert.equal(seen[0].source, 'api', 'source defaults rather than going undefined');
  stop();
});
