/**
 * sessionManager.js - Registry of active SSE sessions.
 *
 * Session shape (contract):
 *   { sessionId, clientId, res, timer, heartbeat, startedAt }
 *     sessionId : crypto.randomUUID(), unique per connection
 *     clientId  : sanitized display label (NOT unique - two tabs may share it)
 *     res       : the live Express/Node response used for SSE writes
 *     timer     : setInterval handle for the 500 ms log loop (this session only)
 *     heartbeat : setInterval handle for the ": ping" comment (this session only)
 *     startedAt : ISO-8601 string
 *
 * This module holds NO timers of its own and no shared log buffers. It is only a
 * Map plus the guarantee that removing a session also clears that session's timers,
 * so nothing can leak no matter which code path removes it.
 */
'use strict';

/** sessionId -> session */
const sessions = new Map();

/** Register a session. Returns the same object for convenience. */
function add(session) {
  if (!session || typeof session.sessionId !== 'string' || session.sessionId === '') {
    throw new TypeError('sessionManager.add: session.sessionId is required');
  }
  sessions.set(session.sessionId, session);
  return session;
}

/**
 * Remove a session and clear its timers. Idempotent: calling it again (or for an
 * unknown id) is a harmless no-op.
 * @returns {boolean} true if a session was actually removed, false otherwise
 */
function remove(sessionId) {
  const session = sessions.get(sessionId);
  if (!session) return false;

  sessions.delete(sessionId);
  if (session.timer) {
    clearInterval(session.timer);
    session.timer = null;
  }
  if (session.heartbeat) {
    clearInterval(session.heartbeat);
    session.heartbeat = null;
  }
  return true;
}

/** @returns {object|undefined} the session for this id */
function get(sessionId) {
  return sessions.get(sessionId);
}

/**
 * All sessions carrying this clientId label. Several tabs may share one label,
 * so this returns an array (possibly empty), never a single session.
 */
function findByClientId(clientId) {
  const matches = [];
  for (const session of sessions.values()) {
    if (session.clientId === clientId) matches.push(session);
  }
  return matches;
}

/** @returns {object[]} snapshot array of all active sessions */
function all() {
  return Array.from(sessions.values());
}

/** @returns {number} number of active sessions */
function count() {
  return sessions.size;
}

/**
 * Server-initiated shutdown of every session: clear timers, drop from the map,
 * end the response. Used by graceful shutdown (Phase 9).
 * @returns {number} how many sessions were closed
 */
function closeAll() {
  const snapshot = all();
  for (const session of snapshot) {
    remove(session.sessionId);
    const res = session.res;
    try {
      if (res && !res.writableEnded && !res.destroyed) res.end();
    } catch (_err) {
      // Socket already broken; the timers are cleared and the entry is gone.
    }
  }
  return snapshot.length;
}

module.exports = { add, remove, get, findByClientId, all, count, closeAll };
