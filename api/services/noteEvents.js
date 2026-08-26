// Fan-out for "the account's notes changed". One process, one Map, no broker:
// there is a single API container, and the moment there are two this has to
// move behind Redis pub/sub — the map records that under "Not yet specified".

const HEARTBEAT_MS = 25_000;
// Proxies and phones drop a stream that says nothing for long enough, and the
// client cannot tell a quiet account from a dead socket. A comment line every
// 25s is cheap and keeps both honest.

const rooms = new Map();

const roomKey = (principal) => `${principal.constructor.modelName}:${principal._id.toString()}`;

export const subscribe = (principal, send) => {
  const key = roomKey(principal);
  const room = rooms.get(key) || new Set();
  room.add(send);
  rooms.set(key, room);

  return () => {
    const current = rooms.get(key);
    if (!current) return;
    current.delete(send);
    if (!current.size) rooms.delete(key);
  };
};

/// Announces a new database version to every other tab and device on this
/// account. The payload carries the version and the ids that moved, never the
/// notes themselves: a listener refetches what it cares about, and a note's
/// text never has to be broadcast to a tab that is not showing it.
export const publish = (principalId, modelName, { version, noteIds = [], source = 'api' }) => {
  const room = rooms.get(`${modelName}:${principalId.toString()}`);
  if (!room?.size) return;
  const payload = JSON.stringify({ version, noteIds, source });
  for (const send of room) {
    // One broken pipe must not stop the announcement reaching the others.
    try { send(payload); } catch { /* the stream's own close handler unsubscribes it */ }
  }
};

export const heartbeatInterval = HEARTBEAT_MS;
export const roomCount = () => rooms.size;
