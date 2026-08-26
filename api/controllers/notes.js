import { randomUUID } from 'node:crypto';
import { apiError, assertColor } from '../middleware/validate.js';
import { flushNotes, mutateNotes, readNotes } from '../services/noteDatabase.js';
import {
  normalizeWindowLevel,
  parseAttachments,
  parseImages,
  serializeAttachments,
  serializeImages,
} from '../services/noteSnapshot.js';

// The web client's view of a note. Two translations happen here and nowhere
// else: the snapshot's REAL seconds become ISO strings, and its two-value
// window_level becomes the boolean the product actually means by 置顶.
export const serializeNote = (note) => ({
  id: note.id,
  text: note.text,
  color: note.color,
  type: note.type,
  images: parseImages(note.images),
  attachments: parseAttachments(note.attachments),
  pinned: note.windowLevel === 'pinned',
  updatedAt: new Date(note.updatedAt * 1000).toISOString(),
  deletedAt: note.deletedAt === null ? null : new Date(note.deletedAt * 1000).toISOString(),
});

// Seconds since the epoch with a fractional part, the way Foundation writes
// timeIntervalSince1970 — the unit the snapshot column is in.
const now = () => Date.now() / 1000;

const MAX_TEXT_BYTES = 256 * 1024;

const assertText = (value) => {
  if (typeof value !== 'string') {
    throw apiError(422, 'VALIDATION_ERROR', 'text must be a string.');
  }
  // The 10 MB database limit is enforced on the whole snapshot, which is a
  // confusing place to discover that one note grew unreasonable.
  if (Buffer.byteLength(value, 'utf8') > MAX_TEXT_BYTES) {
    throw apiError(422, 'NOTE_TOO_LARGE', 'This note is too long.', { limitBytes: MAX_TEXT_BYTES });
  }
  return value;
};

const findNote = (notes, id) => {
  const note = notes.find((candidate) => candidate.id === id);
  if (!note) throw apiError(404, 'NOTE_NOT_FOUND', 'That note no longer exists.');
  return note;
};

const replace = (notes, next) => notes.map((note) => (note.id === next.id ? next : note));

// The four mutations, kept pure and separate from their request handling: they
// take the account's notes and give back the replacement set, which is the
// contract `mutateNotes` wants and also the only shape that can be tested
// without Mongo, OSS, or a listening server.

export const applyCreate = (notes, draft) => {
  if (notes.some((candidate) => candidate.id === draft.id)) {
    throw apiError(409, 'NOTE_EXISTS', 'A note with that id already exists.');
  }
  const created = {
    id: draft.id,
    text: draft.text,
    color: draft.color,
    images: '[]',
    type: draft.type,
    // Stamped by the server, never by the browser. Last-writer-wins compares
    // these across devices, so one clock has to own them or a skewed laptop
    // would quietly win every conflict.
    updatedAt: draft.at,
    deletedAt: null,
    attachments: '[]',
    windowLevel: normalizeWindowLevel(draft.pinned ? 'pinned' : 'normal'),
  };
  return { notes: [...notes, created], result: created };
};

export const applyUpdate = (notes, id, patch, at) => {
  const existing = findNote(notes, id);
  if (existing.deletedAt !== null) {
    throw apiError(409, 'NOTE_DELETED', 'That note is in the trash. Restore it first.');
  }
  const next = { ...existing, ...patch, updatedAt: at };
  return { notes: replace(notes, next), result: next };
};

export const applyDelete = (notes, id, at) => {
  const existing = findNote(notes, id);
  // Deleting twice is not an error: a client retrying a lost response should
  // get the same answer as the one that succeeded.
  if (existing.deletedAt !== null) return { notes, result: existing, changed: false };
  // A tombstone is a row, not a removal — the deletion has to reach the other
  // devices, so the note stays and grows a deletedAt.
  const next = { ...existing, deletedAt: at, updatedAt: at };
  return { notes: replace(notes, next), result: next };
};

export const applyRestore = (notes, id, at) => {
  const existing = findNote(notes, id);
  if (existing.deletedAt === null) return { notes, result: existing, changed: false };
  const next = { ...existing, deletedAt: null, updatedAt: at };
  return { notes: replace(notes, next), result: next };
};

export const listNotes = async (req, res) => {
  const notes = await readNotes(req.user);
  // Tombstones travel too: the trash is a view of them, and a client that
  // filtered them out server-side could never show it.
  res.json({ notes: notes.map(serializeNote) });
};

export const createNote = async (req, res) => {
  const color = req.body?.color ?? 'white';
  assertColor(color);
  const text = assertText(req.body?.text ?? '');
  // The id is the client's UUID, as it is for macOS — the snapshot's primary
  // key is generated at the edge, never by the server.
  const id = typeof req.body?.id === 'string' && req.body.id.trim() ? req.body.id.trim() : randomUUID();

  const type = typeof req.body?.type === 'string' && req.body.type.trim() ? req.body.type.trim() : 'text';
  const note = await mutateNotes(req.user, (notes) =>
    applyCreate(notes, { id, text, color, type, pinned: req.body?.pinned, at: now() }));

  res.status(201).json({ note: serializeNote(note) });
};

export const updateNote = async (req, res) => {
  const patch = {};
  if (Object.hasOwn(req.body ?? {}, 'text')) patch.text = assertText(req.body.text);
  if (Object.hasOwn(req.body ?? {}, 'color')) {
    assertColor(req.body.color);
    patch.color = req.body.color;
  }
  if (Object.hasOwn(req.body ?? {}, 'pinned')) {
    patch.windowLevel = req.body.pinned ? 'pinned' : 'normal';
  }
  if (Object.hasOwn(req.body ?? {}, 'images')) {
    if (!Array.isArray(req.body.images)) {
      throw apiError(422, 'VALIDATION_ERROR', 'images must be an array.');
    }
    patch.images = serializeImages(req.body.images);
  }
  if (Object.hasOwn(req.body ?? {}, 'attachments')) {
    if (!Array.isArray(req.body.attachments)) {
      throw apiError(422, 'VALIDATION_ERROR', 'attachments must be an array.');
    }
    patch.attachments = serializeAttachments(req.body.attachments);
  }
  if (!Object.keys(patch).length) {
    throw apiError(422, 'VALIDATION_ERROR', 'Nothing to change.');
  }

  const note = await mutateNotes(req.user, (notes) => applyUpdate(notes, req.params.id, patch, now()));

  res.json({ note: serializeNote(note) });
};

export const deleteNote = async (req, res) => {
  const note = await mutateNotes(req.user, (notes) => applyDelete(notes, req.params.id, now()));

  res.json({ note: serializeNote(note) });
};

export const restoreNote = async (req, res) => {
  const note = await mutateNotes(req.user, (notes) => applyRestore(notes, req.params.id, now()));

  res.json({ note: serializeNote(note) });
};

// Writes are debounced, which is invisible until something needs the snapshot
// to be current right now — signing out, or a test asserting what a macOS
// client would download.
export const flushNoteDatabase = async (req, res) => {
  await flushNotes(req.user);
  res.status(204).end();
};
