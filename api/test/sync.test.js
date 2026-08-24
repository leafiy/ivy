import test from 'node:test';
import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import {
  baseVersionFilter,
  decodeDatabasePayload,
  isSQLiteDatabase,
  parseBaseVersion,
} from '../controllers/sync.js';
import { NOTE_DATABASE_LIMIT_BYTES } from '../services/quota.js';

const sqliteBytes = (size = 64) => {
  const buffer = Buffer.alloc(size);
  buffer.write('SQLite format 3\0', 0, 'binary');
  return buffer;
};

test('parseBaseVersion accepts absent values as legacy uploads', () => {
  assert.equal(parseBaseVersion(undefined), null);
  assert.equal(parseBaseVersion(null), null);
  assert.equal(parseBaseVersion(''), null);
});

test('parseBaseVersion parses non-negative integers', () => {
  assert.equal(parseBaseVersion('0'), 0);
  assert.equal(parseBaseVersion('42'), 42);
});

test('parseBaseVersion rejects garbage', () => {
  for (const value of ['-1', '1.5', 'abc', '1e3x']) {
    assert.throws(() => parseBaseVersion(value), (error) => error.code === 'BASE_VERSION_INVALID');
  }
});

test('uncompressed payloads pass through untouched', () => {
  const buffer = sqliteBytes();
  assert.equal(decodeDatabasePayload(buffer, undefined), buffer);
  assert.equal(decodeDatabasePayload(buffer, ''), buffer);
});

test('raw deflate payloads decompress back to the original bytes', () => {
  const original = sqliteBytes(4096);
  const compressed = zlib.deflateRawSync(original);
  const decoded = decodeDatabasePayload(compressed, 'deflate');
  assert.ok(original.equals(decoded));
  assert.ok(isSQLiteDatabase(decoded));
});

test('unknown encodings are rejected', () => {
  assert.throws(
    () => decodeDatabasePayload(sqliteBytes(), 'gzip'),
    (error) => error.code === 'ENCODING_UNSUPPORTED'
  );
});

test('undecompressable payloads are rejected as invalid', () => {
  assert.throws(
    () => decodeDatabasePayload(Buffer.from('not deflate data'), 'deflate'),
    (error) => error.code === 'DATABASE_INVALID'
  );
});

test('decompression bombs hit the quota error, not a 500', () => {
  const bomb = zlib.deflateRawSync(Buffer.alloc(NOTE_DATABASE_LIMIT_BYTES + 1024 * 1024));
  assert.throws(
    () => decodeDatabasePayload(bomb, 'deflate'),
    (error) => error.code === 'NOTE_DATABASE_LIMIT' && error.statusCode === 403
  );
});

test('isSQLiteDatabase only accepts the SQLite 3 magic header', () => {
  assert.equal(isSQLiteDatabase(sqliteBytes()), true);
  assert.equal(isSQLiteDatabase(Buffer.from('SQLite format 4\0 nope')), false);
  assert.equal(isSQLiteDatabase(Buffer.from('short')), false);
  assert.equal(isSQLiteDatabase('SQLite format 3\0 not a buffer'), false);
});

test('baseVersion 0 matches accounts that never synced', () => {
  const filter = baseVersionFilter(0);
  assert.deepEqual(filter, {
    $or: [
      { 'databaseSync.version': 0 },
      { 'databaseSync.version': { $exists: false } },
      { databaseSync: null },
    ],
  });
});

test('positive baseVersion matches the stored version exactly', () => {
  assert.deepEqual(baseVersionFilter(3), { 'databaseSync.version': 3 });
});
