/**
 * server.js - LogStream HTTP entry point.
 *
 * Phase 1: static file server.
 * Phase 3: GET /stream (SSE) and GET /api/debug/sessions.
 * Phase 8: POST /api/inject (bonus B3, custom log injection).
 * Phase 9: hardening (MAX_SESSIONS cap, backpressure, graceful shutdown, clean 404 / 500).
 */
'use strict';

const path = require('path');
const crypto = require('crypto');
const express = require('express');

const { generateLog, formatTimestamp } = require('./logEngine');
const sessionManager = require('./sessionManager');

// ---- Constants (fixed by the project contract) ------------------------------
// PORT can be overridden from the environment: `PORT=4000 npm start`.
const PORT = Number(process.env.PORT) || 3000;
const LOG_INTERVAL_MS = 500; // one log line per connection every 500 ms
const HEARTBEAT_MS = 15000; // ": ping" comment keeps proxies from closing idle streams
const CLIENT_ID_MAX = 30;
const MAX_SESSIONS = 100; // /stream answers 503 beyond this many live sessions
const DEFAULT_CLIENT_ID = 'anonymous';
const INJECT_MAX_CHARS = 200; // max length of an injected message (after cleaning)

// ---- Phase 8 implementation details (not part of the contract) ----------------
const INJECT_BODY_LIMIT = '1kb'; // JSON body size cap for POST /api/inject
const INJECT_TARGET_MAX = 64; // sessionId is 36 chars, clientId max 30
const INJECT_RATE_MAX = 10; // requests allowed per IP per window...
const INJECT_RATE_WINDOW_MS = 10000; // ...in a fixed 10 s window
const INJECT_RATE_MAX_TRACKED = 1000; // sweep expired buckets once the map grows past this

// ---- Phase 9 implementation details (not part of the contract) -----------------
const BACKPRESSURE_MAX_SKIPPED_TICKS = 10; // 10 x 500 ms = 5 s of a client that cannot keep up -> drop it
const SHUTDOWN_GRACE_MS = 1000; // after SIGINT/SIGTERM: wait this long, then destroy leftover sockets
const SHUTDOWN_FORCE_MS = 5000; // hard exit if the server still has not closed

const app = express();
let shuttingDown = false; // set by graceful shutdown; /stream refuses new sessions meanwhile

// Serve everything in ./public (index.html, style.css, app.js, inject.html).
// express.static maps "/" to public/index.html automatically.
app.use(express.static(path.join(__dirname, 'public')));

// ---- Helpers ----------------------------------------------------------------

/**
 * Server-side clientId sanitization: allow only letters, digits, space, "-" and "_",
 * trim, cap at CLIENT_ID_MAX chars, fall back to "anonymous". The value is only a
 * label, never used as a key. (Phase 9 tests this thoroughly.)
 */
function sanitizeClientId(raw) {
  if (typeof raw !== 'string') return DEFAULT_CLIENT_ID;
  const cleaned = raw
    .replace(/[^A-Za-z0-9 _-]/g, '')
    .trim()
    .slice(0, CLIENT_ID_MAX)
    .trim();
  return cleaned || DEFAULT_CLIENT_ID;
}

/** True when nothing more can be written to this response. */
function isResponseDead(res) {
  return res.writableEnded || res.destroyed || Boolean(res.socket && res.socket.destroyed);
}

/** One SSE frame: named event + single-line JSON data (JSON.stringify never emits raw newlines). */
function sseFrame(eventName, payload) {
  return `event: ${eventName}\ndata: ${JSON.stringify(payload)}\n\n`;
}

// ---- GET /stream (SSE) ------------------------------------------------------
// Everything a connection owns (id, timers, closed flag) lives in this handler's
// closure, so sessions cannot share state or bleed into each other.
app.get('/stream', (req, res) => {
  // Refuse BEFORE allocating anything (no session object, no timers, no listeners).
  if (shuttingDown) {
    res.set('Retry-After', '5');
    return res.status(503).json({ error: 'server is shutting down' });
  }
  if (sessionManager.count() >= MAX_SESSIONS) {
    res.set('Retry-After', '5');
    return res.status(503).json({ error: `too many active streams (max ${MAX_SESSIONS})` });
  }

  const sessionId = crypto.randomUUID();
  const clientId = sanitizeClientId(req.query.clientId);
  const shortId = sessionId.slice(0, 8);

  const session = {
    sessionId,
    clientId,
    res,
    timer: null,
    heartbeat: null,
    startedAt: new Date().toISOString(),
  };

  // Idempotent cleanup. Safe to call from any number of close/error/guard paths.
  // sessionManager.remove() clears this session's timers and deletes it from the map.
  let closed = false;
  function cleanup(reason) {
    if (closed) return;
    closed = true;
    sessionManager.remove(sessionId);
    console.log(
      `[LogStream] - session ${shortId} client="${clientId}" closed (${reason}), active=${sessionManager.count()}`
    );
    if (!isResponseDead(res)) {
      try {
        // A client that stopped reading will never flush a graceful end(): destroy the socket.
        if (reason === 'backpressure') res.destroy();
        else res.end();
      } catch (_err) {
        /* socket already gone */
      }
    }
  }

  // Backpressure: res.write() === false means the client is not draining its socket.
  // Stop producing until 'drain'; if it never drains, drop the session (no unbounded buffering).
  let blocked = false;
  let skippedTicks = 0;
  res.on('drain', () => {
    blocked = false;
    skippedTicks = 0;
  });

  // Write guard: never write to a dead response, clean up instead.
  function send(chunk) {
    if (isResponseDead(res)) {
      cleanup('write guard');
      return false;
    }
    try {
      if (res.write(chunk) === false) blocked = true;
      return true;
    } catch (_err) {
      cleanup('write error');
      return false;
    }
  }

  const tick = () => {
    if (blocked) {
      skippedTicks += 1;
      if (skippedTicks >= BACKPRESSURE_MAX_SKIPPED_TICKS) cleanup('backpressure');
      return;
    }
    send(sseFrame('log', generateLog()));
  };
  const ping = () => {
    if (!blocked) send(': ping\n\n');
  };

  // Register every disconnect path BEFORE doing anything else.
  req.on('close', () => cleanup('req close'));
  res.on('close', () => cleanup('res close'));
  res.on('error', () => cleanup('res error'));

  // SSE headers, exactly per contract.
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  res.flushHeaders();

  // Long-lived socket: no idle timeout, no Nagle delay on 500 ms writes.
  if (req.socket) {
    req.socket.setTimeout(0);
    req.socket.setNoDelay(true);
    req.socket.setKeepAlive(true);
  }

  // Register and start THIS session's timers first, then send. If a write below
  // trips the guard, cleanup() finds the timers on the session and clears them, so
  // there is no window in which a timer can be created after cleanup ran.
  sessionManager.add(session);
  session.timer = setInterval(tick, LOG_INTERVAL_MS);
  session.heartbeat = setInterval(ping, HEARTBEAT_MS);
  console.log(
    `[LogStream] + session ${shortId} client="${clientId}" opened, active=${sessionManager.count()}`
  );

  // Contract order: "session" event first, then the first log immediately.
  send(sseFrame('session', { sessionId, clientId }));
  tick();
});

// ---- GET /api/debug/sessions ------------------------------------------------
// Only plain fields: `res` and timer handles are not serializable (and not for clients).
app.get('/api/debug/sessions', (_req, res) => {
  const { rss, heapUsed } = process.memoryUsage();
  res.set('Cache-Control', 'no-store');
  res.json({
    active: sessionManager.count(),
    sessions: sessionManager.all().map(({ sessionId, clientId, startedAt }) => ({
      sessionId,
      clientId,
      startedAt,
    })),
    memory: { rss, heapUsed },
  });
});

// ---- POST /api/inject (B3: custom log injection) ----------------------------
// Body: { "message": string, "target": "<sessionId>|<clientId>|all" }
// 200 {delivered:N} | 400 invalid | 404 no such target | 429 rate limited.
//
// Injection adds NO timers and never touches a session's log loop: it writes one
// extra `injected` frame straight to the target's existing response, so the 500 ms
// cadence of every stream is unchanged and each target gets the line exactly once.

// ip -> { count, resetAt }. Pruned lazily (no setInterval: the leak test counts timers).
const injectBuckets = new Map();

/** Fixed-window per-IP rate limit. Runs BEFORE body parsing so spam is rejected cheaply. */
function injectRateLimit(req, res, next) {
  const now = Date.now();
  if (injectBuckets.size > INJECT_RATE_MAX_TRACKED) {
    for (const [ip, bucket] of injectBuckets) {
      if (bucket.resetAt <= now) injectBuckets.delete(ip);
    }
  }

  const ip = req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
  let bucket = injectBuckets.get(ip);
  if (!bucket || bucket.resetAt <= now) {
    bucket = { count: 0, resetAt: now + INJECT_RATE_WINDOW_MS };
    injectBuckets.set(ip, bucket);
  }
  bucket.count += 1;

  if (bucket.count > INJECT_RATE_MAX) {
    const retryAfterSeconds = Math.max(1, Math.ceil((bucket.resetAt - now) / 1000));
    res.set('Retry-After', String(retryAfterSeconds));
    return res.status(429).json({ error: 'rate limit exceeded', retryAfterSeconds });
  }
  return next();
}

// Every ASCII control character (includes \r, \n, \t, NUL), DEL, and the Unicode line/paragraph
// separators. Replaced by a space so words never glue together; a forged SSE event needs a
// newline, so none can survive. (JSON.stringify in sseFrame escapes them again as a second layer.)
const CONTROL_CHARS = /[\u0000-\u001F\u007F\u2028\u2029]+/g;

/** Strip control characters, then trim. Returns null when `raw` is not a string. */
function cleanInjectMessage(raw) {
  if (typeof raw !== 'string') return null;
  return raw.replace(CONTROL_CHARS, ' ').trim();
}

/** Sessions a target string refers to: "all", one sessionId, or every session with that clientId. */
function resolveInjectTargets(target) {
  if (target === 'all') return sessionManager.all();
  const bySessionId = sessionManager.get(target);
  if (bySessionId) return [bySessionId];
  return sessionManager.findByClientId(target);
}

/** Write one frame to a session that is NOT inside its own /stream closure. Same write guard. */
function deliver(session, chunk) {
  const { res } = session;
  if (isResponseDead(res)) {
    sessionManager.remove(session.sessionId); // clears its timers; idempotent with the close handlers
    return false;
  }
  try {
    res.write(chunk);
    return true;
  } catch (_err) {
    sessionManager.remove(session.sessionId);
    return false;
  }
}

function badRequest(res, error) {
  return res.status(400).json({ error });
}

app.post(
  '/api/inject',
  injectRateLimit,
  express.json({ limit: INJECT_BODY_LIMIT }),
  (req, res) => {
    const body = req.body; // undefined when Content-Type is not JSON (Express 5)
    if (!body || typeof body !== 'object' || Array.isArray(body)) {
      return badRequest(res, 'body must be a JSON object sent with Content-Type: application/json');
    }

    const message = cleanInjectMessage(body.message);
    if (message === null) return badRequest(res, '"message" must be a string');
    if (message === '') return badRequest(res, '"message" must not be empty');
    if (message.length > INJECT_MAX_CHARS) {
      return badRequest(res, `"message" must be at most ${INJECT_MAX_CHARS} characters`);
    }

    const target = typeof body.target === 'string' ? body.target.trim() : '';
    if (target === '' || target.length > INJECT_TARGET_MAX) {
      return badRequest(res, '"target" must be a sessionId, a clientId, or "all"');
    }

    const recipients = resolveInjectTargets(target);
    if (recipients.length === 0) {
      return res.status(404).json({ error: 'no such target', delivered: 0 });
    }

    // Same shape as a log entry, standard HH:MM:SS.mmm timestamp, level CUSTOM.
    const timestamp = formatTimestamp(new Date());
    const frame = sseFrame('injected', {
      level: 'CUSTOM',
      timestamp,
      message,
      line: `[CUSTOM] ${timestamp} - ${message}`,
    });

    let delivered = 0;
    for (const session of recipients) {
      if (deliver(session, frame)) delivered += 1;
    }

    console.log(`[LogStream] > inject target=${JSON.stringify(target)} delivered=${delivered}`);
    if (delivered === 0) {
      return res.status(404).json({ error: 'no such target', delivered: 0 });
    }
    return res.json({ delivered });
  },
  // Route-scoped error handler: body-parser failures (malformed JSON, body over 1kb, bad
  // charset) become a clean 400 instead of Express's HTML error page. Phase 9 adds the global one.
  (err, _req, res, next) => {
    if (res.headersSent) return next(err);
    const status = err && (err.status || err.statusCode);
    if (status >= 400 && status < 500) {
      const reason =
        err.type === 'entity.too.large'
          ? `request body too large (max ${INJECT_BODY_LIMIT})`
          : err.type === 'entity.parse.failed'
            ? 'malformed JSON'
            : 'invalid request body';
      return badRequest(res, reason);
    }
    return next(err);
  }
);

// ---- 404 + global error handler (Phase 9) -------------------------------------
// Must come after every route. Unknown API paths get JSON, everything else plain text.
app.use((req, res) => {
  if (req.path.startsWith('/api/')) return res.status(404).json({ error: 'not found' });
  return res.status(404).type('text/plain').send('404 Not Found');
});

// Any error that reaches here becomes a clean response; the process keeps running.
// Only the message is logged (no stack), so the output stays easy to read.
app.use((err, req, res, next) => {
  const status = err && (err.status || err.statusCode);
  const code = status >= 400 && status < 600 ? status : 500;
  if (code >= 500) {
    console.error(`[LogStream] ! error on ${req.method} ${req.originalUrl}: ${err && err.message}`);
  }
  if (res.headersSent) {
    // Mid-response (e.g. an SSE stream): nothing more can be sent, drop the socket.
    res.destroy();
    return;
  }
  res.status(code).json({ error: code >= 500 ? 'internal server error' : 'bad request' });
});

// Last line of defence: log and keep serving instead of dying on a stray error.
process.on('uncaughtException', (err) => {
  console.error(`[LogStream] ! uncaught exception: ${err && err.message}`);
});
process.on('unhandledRejection', (reason) => {
  console.error(`[LogStream] ! unhandled rejection: ${reason && reason.message ? reason.message : reason}`);
});

const server = app.listen(PORT, () => {
  console.log(`[LogStream] listening on http://localhost:${PORT}`);
});

// ---- Graceful shutdown (Phase 9) -------------------------------------------------
// SIGINT / SIGTERM: stop taking new streams, end every response, clear every timer
// (sessionManager.closeAll does both), close the listener, then exit 0.
function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[LogStream] ${signal} received, shutting down...`);

  const closed = sessionManager.closeAll();
  console.log(`[LogStream] ended ${closed} session(s), no timers left`);

  server.close(() => {
    console.log('[LogStream] server closed');
    process.exit(0);
  });
  if (typeof server.closeIdleConnections === 'function') server.closeIdleConnections();

  // Keep-alive sockets can hold server.close() open: destroy them after a short grace,
  // and exit hard if something is still stuck.
  setTimeout(() => {
    if (typeof server.closeAllConnections === 'function') server.closeAllConnections();
  }, SHUTDOWN_GRACE_MS).unref();
  setTimeout(() => {
    console.error('[LogStream] ! forced exit (shutdown took too long)');
    process.exit(1);
  }, SHUTDOWN_FORCE_MS).unref();
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));

module.exports = { app, server };
