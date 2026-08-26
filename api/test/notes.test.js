import test from 'node:test';
import assert from 'node:assert/strict';
import {
  applyCreate,
  applyDelete,
  applyRestore,
  applyUpdate,
  serializeNote,
} from '../controllers/notes.js';
import { mergeNotes, writeSnapshot, readSnapshot } from '../services/noteSnapshot.js';

const seed = (overrides = {}) => ({
  id: 'note-1',
  text: 'hello',
  color: 'white',
  images: '[]',
  type: 'text',
  updatedAt: 1_700_000_000,
  deletedAt: null,
  attachments: '[]',
  windowLevel: 'normal',
  ...overrides,
});

test('the web note shape translates seconds and pin state, and nothing else', () => {
  const note = serializeNote(seed({
    updatedAt: 1_700_000_000.5,
    deletedAt: 1_700_000_100,
    windowLevel: 'pinned',
    images: '["https://oss/a.png"]',
    attachments: '[{"url":"https://oss/b.pdf","name":"b.pdf","sizeBytes":9,"contentType":"application/pdf"}]',
  }));

  // Snapshot seconds out, ISO in. A note stored at 1_700_000_000.5 that came
  // back as 1970 would mean the column had been read as milliseconds.
  assert.equal(note.updatedAt, '2023-11-14T22:13:20.500Z');
  assert.equal(note.deletedAt, '2023-11-14T22:15:00.000Z');
  assert.equal(note.pinned, true);
  assert.deepEqual(note.images, ['https://oss/a.png']);
  assert.equal(note.attachments[0].name, 'b.pdf');
  // window_level never leaks: the client speaks of a note being pinned.
  assert.equal(Object.hasOwn(note, 'windowLevel'), false);
  assert.equal(serializeNote(seed()).deletedAt, null);
});

test('creating a note stamps the server clock and defaults to unpinned', () => {
  const { notes, result } = applyCreate([], {
    id: 'fresh', text: 'x', color: 'green', type: 'text', pinned: false, at: 1_700_000_500,
  });

  assert.equal(notes.length, 1);
  assert.equal(result.updatedAt, 1_700_000_500);
  assert.equal(result.deletedAt, null);
  assert.equal(result.windowLevel, 'normal');
  assert.equal(result.images, '[]');
  assert.equal(result.attachments, '[]');
});

test('creating over an existing id is refused rather than silently merged', () => {
  assert.throws(
    () => applyCreate([seed()], { id: 'note-1', text: '', color: 'white', type: 'text', at: 1 }),
    (error) => error.statusCode === 409 && error.code === 'NOTE_EXISTS'
  );
});

test('an update touches only what was sent and always moves the clock', () => {
  const { result } = applyUpdate([seed()], 'note-1', { color: 'blue' }, 1_700_000_900);

  assert.equal(result.color, 'blue');
  assert.equal(result.text, 'hello');
  // The stamp has to move even when only the colour changed: colour syncs, so
  // a device with an older copy must lose the comparison.
  assert.equal(result.updatedAt, 1_700_000_900);
});

test('a note in the trash cannot be edited behind the reader s back', () => {
  assert.throws(
    () => applyUpdate([seed({ deletedAt: 5 })], 'note-1', { text: 'x' }, 9),
    (error) => error.statusCode === 409 && error.code === 'NOTE_DELETED'
  );
});

test('editing or deleting an unknown note is a 404, not a silent create', () => {
  for (const call of [
    () => applyUpdate([], 'ghost', { text: 'x' }, 1),
    () => applyDelete([], 'ghost', 1),
    () => applyRestore([], 'ghost', 1),
  ]) {
    assert.throws(call, (error) => error.statusCode === 404 && error.code === 'NOTE_NOT_FOUND');
  }
});

test('delete writes a tombstone and keeps the row', () => {
  const { notes, result } = applyDelete([seed()], 'note-1', 1_700_000_800);

  // The deletion has to reach the other devices, and it travels as a row.
  assert.equal(notes.length, 1);
  assert.equal(result.deletedAt, 1_700_000_800);
  assert.equal(result.updatedAt, 1_700_000_800);
  assert.equal(result.text, 'hello');
});

test('deleting and restoring twice are both no-ops that schedule no write', () => {
  const deleted = applyDelete([seed({ deletedAt: 5, updatedAt: 5 })], 'note-1', 9);
  assert.equal(deleted.changed, false);
  assert.equal(deleted.result.deletedAt, 5);

  const restored = applyRestore([seed()], 'note-1', 9);
  assert.equal(restored.changed, false);
  assert.equal(restored.result.updatedAt, 1_700_000_000);
});

test('restore clears the tombstone and keeps the note s identity', () => {
  const { result } = applyRestore([seed({ deletedAt: 5 })], 'note-1', 1_700_001_000);

  assert.equal(result.deletedAt, null);
  assert.equal(result.id, 'note-1');
  assert.equal(result.text, 'hello');
  assert.equal(result.updatedAt, 1_700_001_000);
});

test('a restore beats a macOS delete it was made after, and loses to one made later', () => {
  // The endpoints and the snapshot merge have to agree about time, or the
  // trash would appear to work and then quietly undo itself on the next sync.
  const restored = applyRestore([seed({ deletedAt: 100, updatedAt: 100 })], 'note-1', 200).result;
  const macDeletedEarlier = seed({ deletedAt: 100, updatedAt: 100 });
  const macDeletedLater = seed({ deletedAt: 300, updatedAt: 300 });

  assert.equal(mergeNotes([macDeletedEarlier], [restored])[0].deletedAt, null);
  assert.equal(mergeNotes([restored], [macDeletedLater])[0].deletedAt, 300);
});

test('an edited note survives a round trip through the snapshot unchanged', () => {
  // The endpoints write into the same array the bridge serialises, so whatever
  // they produce has to be writable as a snapshot row.
  const created = applyCreate([], {
    id: 'round', text: '- [ ] 买菜\n**粗体**', color: 'purple', type: 'text', pinned: true, at: 1_700_002_000.25,
  }).result;
  const { notes } = readSnapshot(writeSnapshot([created]));

  assert.deepEqual(notes[0], created);
  assert.equal(serializeNote(notes[0]).pinned, true);
});
