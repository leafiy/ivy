import { heartbeatInterval, subscribe } from '../services/noteEvents.js';

// Server-sent events rather than a WebSocket: the traffic is one-way, it goes
// through the existing Caddy reverse proxy untouched, and it needs no new
// runtime. The one cost is that EventSource cannot carry an Authorization
// header — so the browser client reads this with fetch + ReadableStream
// instead, which can. That is why this endpoint expects a normal Bearer token
// and not a ticket in the query string, where it would end up in access logs.
export const streamNoteEvents = async (req, res) => {
  res.status(200).set({
    'content-type': 'text/event-stream; charset=utf-8',
    'cache-control': 'no-cache, no-transform',
    connection: 'keep-alive',
    // Caddy does not buffer by default, but an nginx anywhere in front would,
    // and a buffered SSE stream looks exactly like a hung one.
    'x-accel-buffering': 'no',
  });
  res.flushHeaders?.();

  // Tell the client the stream is live before anything happens on it, so it
  // can distinguish "connected and quiet" from "still connecting".
  res.write(`event: ready\ndata: ${JSON.stringify({ ok: true })}\n\n`);

  const unsubscribe = subscribe(req.user, (payload) => {
    res.write(`event: notes\ndata: ${payload}\n\n`);
  });

  const heartbeat = setInterval(() => { res.write(': keep-alive\n\n'); }, heartbeatInterval);
  heartbeat.unref?.();

  const close = () => {
    clearInterval(heartbeat);
    unsubscribe();
  };
  req.on('close', close);
  res.on('close', close);
};
