import { createHash } from 'node:crypto';
import { apiError } from '../middleware/validate.js';
import { NOTE_DATABASE_LIMIT_BYTES, assertNoteDatabaseQuota } from './quota.js';
import { uploadFilesToLatte } from './uploader.js';
import { mergeNotes, readSnapshot, writeSnapshot } from './noteSnapshot.js';
import { publish } from './noteEvents.js';

// How long a burst of edits is allowed to accumulate before it is written back
// to OSS, and the ceiling that keeps a steady typist from deferring the write
// forever. Every edit is already durable in the sense that the client got an
// answer; these only govern how quickly a macOS client can see it.
const FLUSH_DELAY_MS = 2_000;
const MAX_FLUSH_DELAY_MS = 15_000;
// One API container, so the cache is process-local by construction. Adding a
// second instance means moving this out; see the map's "Not yet specified".
const MAX_CACHE_ENTRIES = 200;
const CONFLICT_RETRY_LIMIT = 5;
// A failing flush is usually OSS or Mongo being unreachable, so retrying at
// the debounce interval would just hammer them.
const MAX_RETRY_DELAY_MS = 60_000;

const cache = new Map();

// Optimistic-lock filter: the update only lands when the stored version still
// equals the version the snapshot was based on. baseVersion 0 must also match
// accounts whose databaseSync subdocument was never written.
export const baseVersionFilter = (baseVersion) =>
  baseVersion === 0
    ? {
        $or: [
          { 'databaseSync.version': 0 },
          { 'databaseSync.version': { $exists: false } },
          { databaseSync: null },
        ],
      }
    : { 'databaseSync.version': baseVersion };

const cacheKey = (principal) => `${principal.constructor.modelName}:${principal._id.toString()}`;

const remoteVersionOf = (principal) => Number(principal.databaseSync?.version || 0);

const downloadSnapshot = async (url) => {
  if (!url) return [];
  const response = await fetch(url);
  if (!response.ok) {
    throw apiError(502, 'DATABASE_DOWNLOAD_FAILED', 'Could not read the stored notes database.');
  }
  const buffer = Buffer.from(await response.arrayBuffer());
  // The stored snapshot is quota-checked on the way in, so anything larger is
  // a corrupt or hostile object rather than a legitimately grown database.
  if (buffer.length > NOTE_DATABASE_LIMIT_BYTES) {
    throw apiError(502, 'DATABASE_DOWNLOAD_FAILED', 'Stored notes database is oversized.');
  }
  return readSnapshot(buffer).notes;
};

const evictIfNeeded = () => {
  if (cache.size <= MAX_CACHE_ENTRIES) return;
  for (const [key, entry] of cache) {
    if (cache.size <= MAX_CACHE_ENTRIES) break;
    // Never drop an entry that still owes OSS a write.
    if (entry.dirty || entry.flushing) continue;
    cache.delete(key);
  }
};

const newEntry = (principal) => ({
  model: principal.constructor,
  id: principal._id,
  version: 0,
  notes: [],
  loaded: false,
  dirty: false,
  flushing: false,
  firstDirtyAt: 0,
  timer: null,
  lastUploadedHash: null,
  retryDelayMs: 0,
  // Which notes moved since the last successful write-back, so the change can
  // be announced precisely instead of telling every listener to refetch all.
  pendingIds: new Set(),
  // Every read, mutation, and flush for one account runs through this chain,
  // so a flush can never observe a half-applied mutation.
  chain: Promise.resolve(),
});

const serialize = (entry, body) => {
  const run = entry.chain.then(body, body);
  // Keep the chain alive after a rejection; the caller still sees the failure.
  entry.chain = run.then(() => undefined, () => undefined);
  return run;
};

/// Brings the cached notes in line with what Mongo says the account's current
/// version is. Unflushed local edits are merged over whatever arrived from
/// another device rather than discarded.
const reconcile = async (entry, principal) => {
  const remoteVersion = remoteVersionOf(principal);
  if (entry.loaded && entry.version === remoteVersion) return entry;

  const remoteNotes = await downloadSnapshot(principal.databaseSync?.url || null);
  entry.notes = entry.dirty ? mergeNotes(remoteNotes, entry.notes) : remoteNotes;
  entry.version = remoteVersion;
  entry.loaded = true;
  // Someone else's snapshot is now the stored one, so "identical to what we
  // last uploaded" no longer means "identical to what is stored". Forget it,
  // or a merge that happens to reproduce our old bytes would skip its write.
  entry.lastUploadedHash = null;
  return entry;
};

const entryFor = (principal) => {
  const key = cacheKey(principal);
  let entry = cache.get(key);
  if (!entry) {
    entry = newEntry(principal);
    cache.set(key, entry);
    evictIfNeeded();
  }
  // Refresh the handle: a later request carries a newer document for the same
  // account, and the flush path re-queries by id anyway.
  entry.model = principal.constructor;
  entry.id = principal._id;
  return entry;
};

const armFlushTimer = (entry, delayMs) => {
  if (entry.timer) clearTimeout(entry.timer);
  entry.timer = setTimeout(() => {
    entry.timer = null;
    flushEntry(entry).then(
      () => { entry.retryDelayMs = 0; },
      (error) => {
        console.error('ivy-api: deferred notes-database flush failed', error);
        // The edits are still only here, so keep trying rather than stranding
        // them until the next mutation or shutdown — but back off, because a
        // failure here is usually OSS or Mongo being unreachable.
        entry.retryDelayMs = Math.min(
          (entry.retryDelayMs || FLUSH_DELAY_MS) * 2,
          MAX_RETRY_DELAY_MS
        );
        if (entry.dirty && !entry.timer) armFlushTimer(entry, entry.retryDelayMs);
      }
    );
  }, Math.max(0, delayMs));
  // A pending write must never hold the process open on its own.
  entry.timer.unref?.();
};

const scheduleFlush = (entry) => {
  const now = Date.now();
  if (!entry.firstDirtyAt) entry.firstDirtyAt = now;
  const deadline = Math.min(now + FLUSH_DELAY_MS, entry.firstDirtyAt + MAX_FLUSH_DELAY_MS);
  armFlushTimer(entry, deadline - now);
};

const commit = async (entry, buffer) => {
  const sizeBytes = buffer.length;
  assertNoteDatabaseQuota(sizeBytes);

  const result = await uploadFilesToLatte(
    [{
      buffer,
      size: sizeBytes,
      originalname: 'notes.sqlite',
      mimetype: 'application/vnd.sqlite3',
    }],
    { filePath: `ivy/${entry.id.toString()}/database` }
  );
  const url = result.urls[0];
  if (!url) {
    throw apiError(502, 'UPLOADER_BAD_RESPONSE', 'Uploader did not return a database URL.');
  }

  return entry.model.findOneAndUpdate(
    { _id: entry.id, ...baseVersionFilter(entry.version) },
    {
      $set: {
        'databaseSync.url': url,
        'databaseSync.sizeBytes': sizeBytes,
        'databaseSync.updatedAt': new Date(),
        'databaseSync.sourceDeviceId': 'ivy-web',
      },
      $inc: { 'databaseSync.version': 1 },
    },
    { new: true }
  );
};

/// Writes the cached notes back to OSS under the version they were based on.
/// A macOS client that uploaded in between moves the version out from under
/// us; the answer is to pull its snapshot, merge, and try again, which is why
/// the web client never sees a 409.
const flushEntry = async (entry) => serialize(entry, async () => {
  if (!entry.dirty) return;
  entry.flushing = true;
  try {
    for (let attempt = 0; attempt < CONFLICT_RETRY_LIMIT; attempt += 1) {
      const buffer = writeSnapshot(entry.notes);
      const hash = createHash('sha256').update(buffer).digest('hex');
      // Byte-identical to what we last stored: nothing to say.
      if (hash === entry.lastUploadedHash) {
        entry.dirty = false;
        entry.firstDirtyAt = 0;
        return;
      }

      const current = await entry.model.findById(entry.id);
      if (!current) throw apiError(404, 'NOT_FOUND', 'Account no longer exists.');
      // Fail fast on a base we already know is stale, before paying for OSS.
      if (remoteVersionOf(current) !== entry.version) {
        await reconcile(entry, current);
        continue;
      }

      const updated = await commit(entry, buffer);
      if (updated) {
        entry.version = remoteVersionOf(updated);
        entry.lastUploadedHash = hash;
        entry.dirty = false;
        entry.firstDirtyAt = 0;
        const noteIds = [...entry.pendingIds];
        entry.pendingIds.clear();
        // Only now, with the snapshot actually stored: announcing earlier
        // would tell a macOS client to fetch a version that does not exist.
        publish(entry.id, entry.model.modelName, { version: entry.version, noteIds, source: 'web' });
        return;
      }
      // Lost the race between the version check and the update.
      const latest = await entry.model.findById(entry.id);
      if (!latest) throw apiError(404, 'NOT_FOUND', 'Account no longer exists.');
      await reconcile(entry, latest);
    }
    throw apiError(503, 'DATABASE_BUSY', 'The notes database is changing too fast to save. Try again.');
  } finally {
    entry.flushing = false;
  }
});

/// The account's notes as of right now, including tombstones — the trash view
/// needs them, and every caller filters for itself. The array is a copy: the
/// cached one is the thing that gets written back to OSS, so callers must not
/// hold a handle on it.
export const readNotes = async (principal) => {
  const entry = entryFor(principal);
  return serialize(entry, async () => {
    await reconcile(entry, principal);
    return [...entry.notes];
  });
};

/// Runs `mutate(notes)` against the account's notes, where `notes` is the
/// current array and the return value is
/// `{ notes, result, changed }`:
///   - `notes`   the replacement array (build a new one; do not splice in place)
///   - `result`  whatever the caller wants back, returned verbatim
///   - `changed` pass `false` for a no-op so it schedules no write; anything
///               else, including omitting it, counts as a change
/// The mutation lands before this resolves, so a read that follows it sees the
/// new state even though the write back to OSS is still debounced.
export const mutateNotes = async (principal, mutate) => {
  const entry = entryFor(principal);
  return serialize(entry, async () => {
    await reconcile(entry, principal);
    const outcome = await mutate(entry.notes);
    entry.notes = outcome.notes;
    if (outcome.changed !== false) {
      // `changedIds` if the mutator names them, otherwise the id of whatever
      // it returned — the four note mutations all return the note they touched.
      for (const id of outcome.changedIds ?? (outcome.result?.id ? [outcome.result.id] : [])) {
        entry.pendingIds.add(id);
      }
      entry.dirty = true;
      scheduleFlush(entry);
    }
    return outcome.result;
  });
};

/// Forces the pending write to land now. The endpoints that need a macOS
/// client to see the change immediately can await this instead of the timer.
export const flushNotes = async (principal) => {
  const entry = cache.get(cacheKey(principal));
  if (!entry) return;
  if (entry.timer) {
    clearTimeout(entry.timer);
    entry.timer = null;
  }
  await flushEntry(entry);
};

/// Called when a snapshot arrives from a client: the cached copy is now behind
/// and must not be written back over the newer one.
export const invalidateNotes = (principal) => {
  const entry = cache.get(cacheKey(principal));
  if (!entry) return;
  entry.loaded = false;
};

/// Shutdown hook: a container that stops with debounced edits still in memory
/// would lose them, since online-only means nothing else holds a copy.
export const flushAllNotes = async () => {
  const pending = [...cache.values()].filter((entry) => entry.dirty);
  const results = await Promise.allSettled(pending.map((entry) => {
    if (entry.timer) {
      clearTimeout(entry.timer);
      entry.timer = null;
    }
    return flushEntry(entry);
  }));
  for (const result of results) {
    if (result.status === 'rejected') {
      console.error('ivy-api: notes-database flush failed during shutdown', result.reason);
    }
  }
};
