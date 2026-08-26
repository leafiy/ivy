import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import {
  isSQLiteDatabase,
  mergeNotes,
  normalizeWindowLevel,
  parseAttachments,
  parseImages,
  readSnapshot,
  serializeAttachments,
  serializeImages,
  writeSnapshot,
} from '../services/noteSnapshot.js';

// These tests exist because the notes database now has two writers: Swift's
// NoteStore and this service. Nothing in either language stops them drifting,
// so the shape of the file and the outcome of a merge are pinned here.

const note = (overrides = {}) => ({
  id: 'note-1',
  text: 'hello',
  color: 'white',
  images: '[]',
  type: 'text',
  updatedAt: 1_700_000_000.5,
  deletedAt: null,
  attachments: '[]',
  windowLevel: 'normal',
  ...overrides,
});

const openBuffer = (buffer, body) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ivy-snapshot-test-'));
  const file = path.join(directory, 'notes.sqlite');
  try {
    fs.writeFileSync(file, buffer);
    const database = new DatabaseSync(file);
    try {
      return body(database, file);
    } finally {
      database.close();
    }
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
};

test('a written snapshot has exactly the nine columns Swift writes', () => {
  const buffer = writeSnapshot([note()]);

  assert.equal(isSQLiteDatabase(buffer), true);
  openBuffer(buffer, (database) => {
    const columns = database.prepare('PRAGMA table_info(notes)').all();
    assert.deepEqual(
      columns.map((column) => [column.name, column.type, Number(column.notnull), Number(column.pk)]),
      [
        ['uuid', 'TEXT', 0, 1],
        ['text', 'TEXT', 1, 0],
        ['color', 'TEXT', 1, 0],
        ['images', 'TEXT', 1, 0],
        ['type', 'TEXT', 1, 0],
        ['updated_at', 'REAL', 1, 0],
        ['deleted_at', 'REAL', 0, 0],
        ['attachments', 'TEXT', 1, 0],
        ['window_level', 'TEXT', 1, 0],
      ]
    );

    const indexes = database.prepare('PRAGMA index_list(notes)').all();
    assert.equal(indexes.some((index) => index.name === 'notes_updated_at'), true);

    // Device-local state must never appear: a macOS client reads this file
    // with the same reader it uses for its own database.
    const names = new Set(columns.map((column) => column.name));
    for (const forbidden of ['frame_x', 'frame_y', 'frame_w', 'frame_h', 'window_opacity', 'closed', 'font_size', 'dirty']) {
      assert.equal(names.has(forbidden), false, `${forbidden} must not reach a snapshot`);
    }
  });
});

test('snapshot column defaults match the Swift DDL', () => {
  const buffer = writeSnapshot([]);

  openBuffer(buffer, (database) => {
    // Written the way a client predating attachments and pin state would.
    database
      .prepare('INSERT INTO notes (uuid, text, color, images, type, updated_at) VALUES (?, ?, ?, ?, ?, ?)')
      .run('legacy', 'text', 'white', '[]', 'text', 1);
    const row = database.prepare('SELECT attachments, window_level FROM notes WHERE uuid = ?').get('legacy');
    assert.equal(row.attachments, '[]');
    assert.equal(row.window_level, 'normal');
  });
});

test('snapshots round-trip every field, tombstones and fractional seconds included', () => {
  const notes = [
    note({ id: 'b', text: 'second', color: 'pink', windowLevel: 'pinned' }),
    note({ id: 'a', text: 'first', updatedAt: 1_699_999_999.25, deletedAt: 1_700_000_001.75 }),
  ];

  const { notes: read } = readSnapshot(writeSnapshot(notes));
  const byId = Object.fromEntries(read.map((row) => [row.id, row]));

  assert.equal(read.length, 2);
  assert.deepEqual(byId.a, notes[1]);
  assert.deepEqual(byId.b, notes[0]);
  // Seconds since the epoch, not milliseconds: a millisecond value here would
  // put every note tens of thousands of years in the future and silently win
  // every merge against a real macOS edit.
  assert.equal(byId.a.updatedAt, 1_699_999_999.25);
  assert.equal(byId.a.deletedAt, 1_700_000_001.75);
  assert.equal(byId.b.deletedAt, null);
});

test('the same notes always produce byte-identical snapshots', () => {
  const notes = [note({ id: 'b' }), note({ id: 'a' }), note({ id: 'c' })];
  const shuffled = [notes[2], notes[0], notes[1]];

  assert.deepEqual(writeSnapshot(notes), writeSnapshot(shuffled));
});

test('a snapshot missing the newer columns still reads, with defaults', () => {
  // Exactly the schema a client wrote before attachments and pin state existed.
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ivy-snapshot-old-'));
  const file = path.join(directory, 'old.sqlite');
  let buffer;
  try {
    const database = new DatabaseSync(file);
    database.exec(`
      PRAGMA journal_mode = DELETE;
      CREATE TABLE notes (
          uuid TEXT PRIMARY KEY,
          text TEXT NOT NULL,
          color TEXT NOT NULL,
          images TEXT NOT NULL,
          type TEXT NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL
      );
    `);
    database
      .prepare('INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?)')
      .run('old-note', 'from an old client', 'yellow', '["u"]', 'text', 1_600_000_000, null);
    database.close();
    buffer = fs.readFileSync(file);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }

  const snapshot = readSnapshot(buffer);
  assert.equal(snapshot.hasAttachments, false);
  assert.equal(snapshot.hasWindowLevel, false);
  assert.equal(snapshot.notes.length, 1);
  assert.equal(snapshot.notes[0].attachments, '[]');
  assert.equal(snapshot.notes[0].windowLevel, 'normal');
  assert.equal(snapshot.notes[0].images, '["u"]');
});

test('readSnapshot refuses anything that is not a SQLite file', () => {
  assert.equal(isSQLiteDatabase(Buffer.from('not a database')), false);
  assert.throws(() => readSnapshot(Buffer.from('not a database')), (error) => {
    assert.equal(error.statusCode, 422);
    assert.equal(error.code, 'DATABASE_INVALID');
    return true;
  });
});

test('window level falls back to normal for legacy and unknown values', () => {
  // `NoteWindowLevel.value(for:)` retired "desktop" and defaults anything
  // unrecognised, so a newer client cannot break an older reader.
  assert.equal(normalizeWindowLevel('pinned'), 'pinned');
  assert.equal(normalizeWindowLevel('normal'), 'normal');
  assert.equal(normalizeWindowLevel('desktop'), 'normal');
  assert.equal(normalizeWindowLevel('floating'), 'normal');
  assert.equal(normalizeWindowLevel(undefined), 'normal');

  const { notes } = readSnapshot(writeSnapshot([note({ windowLevel: 'desktop' })]));
  assert.equal(notes[0].windowLevel, 'normal');
});

test('merge keeps the newer note and never resurrects a tombstone', () => {
  const base = [
    note({ id: 'stale', text: 'old', updatedAt: 100 }),
    note({ id: 'fresh', text: 'kept', updatedAt: 300 }),
    note({ id: 'only-base', updatedAt: 100 }),
    note({ id: 'deleted-remotely', text: 'still here', updatedAt: 100 }),
  ];
  const incoming = [
    note({ id: 'stale', text: 'new', updatedAt: 200 }),
    note({ id: 'fresh', text: 'ignored', updatedAt: 200 }),
    note({ id: 'only-incoming', updatedAt: 100 }),
    note({ id: 'deleted-remotely', text: 'still here', updatedAt: 200, deletedAt: 200 }),
  ];

  const merged = Object.fromEntries(mergeNotes(base, incoming).map((row) => [row.id, row]));

  assert.equal(Object.keys(merged).length, 5);
  assert.equal(merged.stale.text, 'new');
  assert.equal(merged.fresh.text, 'kept');
  assert.equal(merged['only-base'].id, 'only-base');
  assert.equal(merged['only-incoming'].id, 'only-incoming');
  assert.equal(merged['deleted-remotely'].deletedAt, 200);
});

test('merge gives an exact tie to the incoming note', () => {
  // Transcribed from applyServerChange: `local.updatedAt > incoming.updatedAt`
  // returns early, so equality falls through and the incoming row is written.
  const merged = mergeNotes(
    [note({ id: 'tie', text: 'base', updatedAt: 500 })],
    [note({ id: 'tie', text: 'incoming', updatedAt: 500 })]
  );
  assert.equal(merged[0].text, 'incoming');
});

test('attachment JSON matches NoteAttachment.CodingKeys', () => {
  const attachments = [
    { url: 'https://oss/a.png', name: 'a.png', sizeBytes: 1024, contentType: 'image/png' },
    { url: 'https://oss/b.pdf', name: 'b.pdf', sizeBytes: 2048, contentType: 'application/pdf' },
  ];
  const json = serializeAttachments(attachments);

  assert.equal(
    json,
    '[{"url":"https://oss/a.png","name":"a.png","sizeBytes":1024,"contentType":"image/png"},'
    + '{"url":"https://oss/b.pdf","name":"b.pdf","sizeBytes":2048,"contentType":"application/pdf"}]'
  );
  assert.deepEqual(parseAttachments(json), attachments);
});

test('a thumbnail left over from an older note is read past and dropped', () => {
  // Previews are gone: images render from the OSS URL directly. Notes written
  // before that may still carry the key, and must neither break the read nor
  // survive the rewrite.
  const legacy = '[{"url":"https://oss/a.png","thumbnailUrl":"https://oss/a-thumb.png","name":"a.png","sizeBytes":1,"contentType":"image/png"}]';
  const parsed = parseAttachments(legacy);

  assert.deepEqual(Object.keys(parsed[0]).sort(), ['contentType', 'name', 'sizeBytes', 'url']);
  assert.equal(parsed[0].url, 'https://oss/a.png');
  assert.equal(serializeAttachments(parsed).includes('thumbnailUrl'), false);
});

test('attachment and image columns degrade instead of throwing', () => {
  // Mirrors the Swift reader, which drops undecodable attachment JSON rather
  // than failing the whole note.
  assert.deepEqual(parseAttachments('not json'), []);
  assert.deepEqual(parseAttachments('{}'), []);
  assert.deepEqual(parseAttachments('[{"name":"no url"}]'), []);
  assert.deepEqual(parseImages('not json'), []);
  assert.deepEqual(parseImages('["a", 2, "b"]'), ['a', 'b']);
  assert.equal(serializeImages(['a', 'b']), '["a","b"]');
});
