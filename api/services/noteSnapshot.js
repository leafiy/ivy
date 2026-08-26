import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { apiError } from '../middleware/validate.js';

// The portable notes snapshot is the sync protocol. Its authority is
// `NoteStore.makeSyncSnapshot` in Sources/IvyCore/NoteStore.swift; this module
// exists so the API can read and write the same file, and every constant below
// is transcribed from there rather than chosen here. Nine columns, no more:
// window frames, opacity, font size, and closed state are device-local and
// must never reach a snapshot.
export const SNAPSHOT_SCHEMA = `
PRAGMA journal_mode = DELETE;
CREATE TABLE notes (
    uuid TEXT PRIMARY KEY,
    text TEXT NOT NULL,
    color TEXT NOT NULL,
    images TEXT NOT NULL,
    type TEXT NOT NULL,
    updated_at REAL NOT NULL,
    deleted_at REAL,
    attachments TEXT NOT NULL DEFAULT '[]',
    window_level TEXT NOT NULL DEFAULT 'normal'
);
CREATE INDEX notes_updated_at ON notes(updated_at);
`;

const SQLITE_HEADER = Buffer.from('SQLite format 3\0', 'binary');

export const isSQLiteDatabase = (buffer) =>
  Buffer.isBuffer(buffer)
  && buffer.length >= 16
  && buffer.subarray(0, 16).equals(SQLITE_HEADER);

// `NoteWindowLevel.value(for:)`: the retired "desktop" value and anything
// unrecognised both fall back to normal, so an old or newer client's pin
// state can never crash a read.
export const normalizeWindowLevel = (value) =>
  value === 'pinned' ? 'pinned' : 'normal';

const withTempDirectory = (body) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ivy-snapshot-'));
  try {
    return body(path.join(directory, 'notes.sqlite'));
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
};

const toNote = (row) => ({
  id: String(row.uuid),
  text: String(row.text ?? ''),
  color: String(row.color ?? ''),
  // images and attachments stay raw JSON text end to end. Re-encoding them
  // would risk drifting from what the Swift encoder wrote for notes this
  // request never touched.
  images: String(row.images ?? '[]'),
  type: String(row.type ?? 'text'),
  // updated_at and deleted_at are SQLite REAL: seconds since the epoch with a
  // fractional part, matching Foundation's timeIntervalSince1970. Not millis.
  updatedAt: Number(row.updated_at),
  deletedAt: row.deleted_at === null || row.deleted_at === undefined
    ? null
    : Number(row.deleted_at),
  attachments: String(row.attachments ?? '[]'),
  windowLevel: normalizeWindowLevel(row.window_level),
});

/// Reads every row of a portable snapshot. Mirrors `NoteStore.readSnapshot`,
/// including its tolerance: snapshots written before attachments and pin state
/// existed simply lack those columns, and default instead of failing.
export const readSnapshot = (buffer) => {
  if (!isSQLiteDatabase(buffer)) {
    throw apiError(422, 'DATABASE_INVALID', 'database must be a SQLite 3 file.');
  }

  return withTempDirectory((file) => {
    fs.writeFileSync(file, buffer);
    const database = new DatabaseSync(file, { readOnly: true });
    try {
      const columns = new Set(
        database.prepare('PRAGMA table_info(notes)').all().map((row) => String(row.name))
      );
      // An account that has never synced can still hold a valid but empty file.
      if (columns.size === 0) return { notes: [], hasAttachments: false, hasWindowLevel: false };

      const hasAttachments = columns.has('attachments');
      const hasWindowLevel = columns.has('window_level');
      const rows = database
        .prepare(`
          SELECT uuid, text, color, images, type, updated_at, deleted_at,
                 ${hasAttachments ? 'attachments' : "'[]'"} AS attachments,
                 ${hasWindowLevel ? 'window_level' : "'normal'"} AS window_level
          FROM notes ORDER BY updated_at
        `)
        .all();
      return { notes: rows.map(toNote), hasAttachments, hasWindowLevel };
    } finally {
      database.close();
    }
  });
};

/// Writes a portable snapshot and returns its bytes. Column order, types, the
/// index, and the DELETE journal mode all have to match the Swift writer: a
/// macOS client opens this file with the same reader it uses for its own.
export const writeSnapshot = (notes) => withTempDirectory((file) => {
  const database = new DatabaseSync(file);
  try {
    database.exec(SNAPSHOT_SCHEMA);
    const insert = database.prepare('INSERT INTO notes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)');
    // Swift exports ORDER BY uuid; matching it keeps two snapshots of the same
    // content byte-identical, which is what lets the caller skip a no-op upload.
    const ordered = [...notes].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    database.exec('BEGIN IMMEDIATE');
    try {
      for (const note of ordered) {
        insert.run(
          note.id,
          note.text ?? '',
          note.color,
          note.images ?? '[]',
          note.type ?? 'text',
          Number(note.updatedAt),
          note.deletedAt === null || note.deletedAt === undefined ? null : Number(note.deletedAt),
          note.attachments ?? '[]',
          normalizeWindowLevel(note.windowLevel)
        );
      }
      database.exec('COMMIT');
    } catch (error) {
      database.exec('ROLLBACK');
      throw error;
    }
  } finally {
    database.close();
  }
  return fs.readFileSync(file);
});

/// Per-note last-writer-wins, transcribed from `NoteStore.applyServerChange`:
/// a strictly newer base row survives, every tie goes to the incoming row, and
/// notes present on only one side always survive. Deletions travel as
/// `deletedAt` tombstones, so they merge like any other field.
export const mergeNotes = (base, incoming) => {
  const merged = new Map();
  for (const note of base) merged.set(note.id, note);
  for (const note of incoming) {
    const local = merged.get(note.id);
    if (local && local.updatedAt > note.updatedAt) continue;
    merged.set(note.id, note);
  }
  return [...merged.values()];
};

// --- the two JSON-encoded columns -------------------------------------------
// Attachment keys are `NoteAttachment.CodingKeys`. An older note may still
// carry a `thumbnailUrl` from before previews were dropped; reading simply
// ignores it, and rewriting the note lets it go.

export const parseImages = (json) => {
  try {
    const value = JSON.parse(json);
    return Array.isArray(value) ? value.filter((item) => typeof item === 'string') : [];
  } catch {
    return [];
  }
};

export const serializeImages = (images) =>
  JSON.stringify((images || []).map((image) => String(image)));

export const parseAttachments = (json) => {
  try {
    const value = JSON.parse(json);
    if (!Array.isArray(value)) return [];
    return value
      .filter((item) => item && typeof item === 'object' && typeof item.url === 'string')
      .map((item) => ({
        url: item.url,
        name: typeof item.name === 'string' ? item.name : '',
        sizeBytes: Number.isFinite(Number(item.sizeBytes)) ? Number(item.sizeBytes) : 0,
        contentType: typeof item.contentType === 'string' ? item.contentType : '',
      }));
  } catch {
    return [];
  }
};

export const serializeAttachments = (attachments) =>
  JSON.stringify((attachments || []).map((attachment) => ({
    url: String(attachment.url),
    name: String(attachment.name ?? ''),
    sizeBytes: Number(attachment.sizeBytes ?? 0),
    contentType: String(attachment.contentType ?? ''),
  })));
