import zlib from 'node:zlib';
import multer from 'multer';
import { apiError } from '../middleware/validate.js';
import { NOTE_DATABASE_LIMIT_BYTES, assertNoteDatabaseQuota } from '../services/quota.js';
import { uploadFilesToLatte } from '../services/uploader.js';
import { baseVersionFilter, invalidateNotes } from '../services/noteDatabase.js';
import { publish } from '../services/noteEvents.js';
import { isSQLiteDatabase } from '../services/noteSnapshot.js';

// Both helpers moved to the services that own the notes database; re-exported
// so the existing callers and tests keep their import site.
export { baseVersionFilter, isSQLiteDatabase };

const storage = multer.memoryStorage();

export const uploadDatabaseMiddleware = multer({
  storage,
  limits: { files: 1, fileSize: NOTE_DATABASE_LIMIT_BYTES },
}).single('database');

const serializeDatabase = (databaseSync) => ({
  version: Number(databaseSync?.version || 0),
  sizeBytes: Number(databaseSync?.sizeBytes || 0),
  updatedAt: databaseSync?.updatedAt ? databaseSync.updatedAt.toISOString() : null,
  downloadURL: databaseSync?.url || null,
  sourceDeviceId: databaseSync?.sourceDeviceId || null,
});

export const parseBaseVersion = (value) => {
  if (value === undefined || value === null || value === '') return null;
  const version = Number(value);
  if (!Number.isInteger(version) || version < 0) {
    throw apiError(422, 'BASE_VERSION_INVALID', 'baseVersion must be a non-negative integer.');
  }
  return version;
};

// Apple's Compression framework emits headerless deflate (COMPRESSION_ZLIB),
// so raw deflate is the one encoding clients send. maxOutputLength keeps
// decompression bombs inside the note-database quota.
export const decodeDatabasePayload = (buffer, contentEncoding) => {
  const encoding = typeof contentEncoding === 'string'
    ? contentEncoding.trim().toLowerCase()
    : '';
  if (!encoding) return buffer;
  if (encoding !== 'deflate') {
    throw apiError(422, 'ENCODING_UNSUPPORTED', 'contentEncoding must be "deflate".');
  }
  try {
    return zlib.inflateRawSync(buffer, { maxOutputLength: NOTE_DATABASE_LIMIT_BYTES + 1 });
  } catch (error) {
    if (error?.code === 'ERR_BUFFER_TOO_LARGE') {
      throw apiError(403, 'NOTE_DATABASE_LIMIT', 'Note database exceeds the 10 MB limit.', {
        limitBytes: NOTE_DATABASE_LIMIT_BYTES,
      });
    }
    throw apiError(422, 'DATABASE_INVALID', 'database payload could not be decompressed.');
  }
};

const databaseConflict = (databaseSync) =>
  apiError(
    409,
    'DATABASE_CONFLICT',
    'The notes database changed on the server. Download and merge before uploading again.',
    { database: serializeDatabase(databaseSync) }
  );

export const databaseStatus = async (req, res) => {
  res.json({ database: serializeDatabase(req.user.databaseSync) });
};

export const uploadDatabase = async (req, res) => {
  const file = req.file;
  if (!file) {
    throw apiError(422, 'DATABASE_REQUIRED', 'database is required.');
  }

  const baseVersion = parseBaseVersion(req.body.baseVersion);
  // Fail fast on an obviously stale base before paying for the OSS upload.
  // The conditional update below still closes the remaining race window.
  if (baseVersion !== null && Number(req.user.databaseSync?.version || 0) !== baseVersion) {
    throw databaseConflict(req.user.databaseSync);
  }

  const buffer = decodeDatabasePayload(file.buffer, req.body.contentEncoding);
  const sizeBytes = buffer.length;
  assertNoteDatabaseQuota(sizeBytes);
  if (!isSQLiteDatabase(buffer)) {
    throw apiError(422, 'DATABASE_INVALID', 'database must be a SQLite 3 file.');
  }

  const databaseFile = {
    ...file,
    buffer,
    size: sizeBytes,
    originalname: 'notes.sqlite',
    mimetype: 'application/vnd.sqlite3',
  };
  const result = await uploadFilesToLatte([databaseFile], {
    filePath: `ivy/${req.user._id.toString()}/database`,
  });
  const url = result.urls[0];
  if (!url) {
    throw apiError(502, 'UPLOADER_BAD_RESPONSE', 'Uploader did not return a database URL.');
  }

  const sourceDeviceId = typeof req.body.deviceId === 'string'
    ? req.body.deviceId.trim().slice(0, 200)
    : null;
  const updatedAt = new Date();
  const Principal = req.user.constructor;
  // Legacy clients send no baseVersion and keep last-writer-wins; clients that
  // do send one can never clobber a version they haven't seen.
  const filter = baseVersion === null
    ? { _id: req.user._id }
    : { _id: req.user._id, ...baseVersionFilter(baseVersion) };
  const user = await Principal.findOneAndUpdate(
    filter,
    {
      $set: {
        'databaseSync.url': url,
        'databaseSync.sizeBytes': sizeBytes,
        'databaseSync.updatedAt': updatedAt,
        'databaseSync.sourceDeviceId': sourceDeviceId,
      },
      $inc: { 'databaseSync.version': 1 },
    },
    { new: true }
  );
  if (!user) {
    const current = await Principal.findById(req.user._id);
    throw databaseConflict(current?.databaseSync);
  }

  // A client just moved the account forward; anything the bridge still holds
  // in memory is now behind and must be re-read before it is written back.
  invalidateNotes(req.user);
  // A whole snapshot arrived, so there is no list of ids to name — an empty
  // one means "everything may have moved, refetch".
  publish(req.user._id, Principal.modelName, {
    version: Number(user.databaseSync?.version || 0),
    noteIds: [],
    source: 'client',
  });

  res.json({ database: serializeDatabase(user.databaseSync) });
};
