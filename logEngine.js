/**
 * logEngine.js - Mock Log Engine (pure module, no HTTP code).
 *
 * Exports:
 *   generateLog([now]) -> { level, timestamp, message, line }
 *     level     : "INFO" | "WARN" | "ERROR"
 *     timestamp : "HH:MM:SS.mmm" (server local time, ms zero-padded to 3 digits)
 *     message   : dynamic text that logically matches the level
 *     line      : "[LEVEL] HH:MM:SS.mmm - message"
 *
 * Level weights: INFO 60%, WARN 25%, ERROR 15%.
 *   INFO  = benign events (healthy requests, cache hits, jobs finishing)
 *   WARN  = degraded resources / slowness (still working, needs attention)
 *   ERROR = failures (5xx, timeouts, crashes, unavailable dependencies)
 *
 * Also exported for tests and reuse: formatTimestamp, pickLevel, LEVELS.
 * Messages never contain "\r" or "\n" so a line is always safe as one SSE data line.
 */
'use strict';

const LEVELS = ['INFO', 'WARN', 'ERROR'];

// Cumulative thresholds out of 100: INFO [0,60), WARN [60,85), ERROR [85,100).
const WEIGHTS = [
  { level: 'INFO', upTo: 60 },
  { level: 'WARN', upTo: 85 },
  { level: 'ERROR', upTo: 100 },
];

// ---- Small random helpers ---------------------------------------------------

/** Integer in [min, max], inclusive. */
function randInt(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

/** Random element of a non-empty array. */
function pick(arr) {
  return arr[Math.floor(Math.random() * arr.length)];
}

const pad = (n, width) => String(n).padStart(width, '0');

// ---- Timestamp --------------------------------------------------------------

/** Format a Date as HH:MM:SS.mmm (local time, ms padded to 3 digits). */
function formatTimestamp(date = new Date()) {
  return (
    `${pad(date.getHours(), 2)}:${pad(date.getMinutes(), 2)}:` +
    `${pad(date.getSeconds(), 2)}.${pad(date.getMilliseconds(), 3)}`
  );
}

// ---- Dynamic value pools ----------------------------------------------------

const ENDPOINTS = [
  '/api/v1/users',
  '/api/v1/users/42',
  '/api/v1/orders',
  '/api/v1/orders/checkout',
  '/api/v1/products',
  '/api/v1/payments',
  '/api/v1/auth/login',
  '/api/v1/auth/refresh',
  '/api/v1/search',
  '/api/v1/notifications',
  '/api/v1/reports/daily',
  '/api/v1/inventory',
];

const SERVICES = [
  'auth-service',
  'payment-gateway',
  'inventory-service',
  'notification-service',
  'search-indexer',
  'user-service',
];

const DATABASES = ['postgres-primary', 'postgres-replica-2', 'redis-cache', 'mongo-analytics'];

const JOBS = ['nightly-backup', 'email-digest', 'cache-warmup', 'report-export', 'session-cleanup'];

const METHODS = ['GET', 'GET', 'GET', 'POST', 'PUT', 'DELETE']; // GET-heavy, like real traffic

const OK_CODES = [200, 200, 200, 201, 204, 304];
const ERROR_CODES = [500, 500, 502, 503, 504];

const USERS = ['alice', 'bob', 'carol', 'dave', 'erin', 'frank', 'grace', 'heidi'];

// ---- Message pools ----------------------------------------------------------
// Each entry is a function so values are re-rolled on every call.

const INFO_MESSAGES = [
  () => `${pick(METHODS)} ${pick(ENDPOINTS)} completed with status ${pick(OK_CODES)} in ${randInt(8, 180)}ms.`,
  () => `Health check passed: ${pick(SERVICES)} responded in ${randInt(2, 45)}ms.`,
  () => `User ${pick(USERS)} logged in successfully from 10.0.${randInt(0, 255)}.${randInt(1, 254)}.`,
  () => `Cache hit for key user:${randInt(1000, 9999)} (${randInt(85, 99)}% hit ratio).`,
  () => `Scheduled job ${pick(JOBS)} finished in ${randInt(120, 4800)}ms.`,
  () => `Database connection to ${pick(DATABASES)} established (pool ${randInt(3, 12)}/20 in use).`,
  () => `Worker ${randInt(1, 8)} processed ${randInt(5, 120)} queued messages.`,
  () => `Ping to ${pick(SERVICES)}: ${randInt(1, 40)}ms.`,
  () => `Memory usage nominal at ${randInt(25, 60)}%.`,
  () => `Configuration reloaded successfully (${randInt(12, 48)} keys).`,
];

const WARN_MESSAGES = [
  () => `Memory usage at ${randInt(78, 92)}%, approaching limit.`,
  () => `Slow response from ${pick(ENDPOINTS)}: ${randInt(1200, 4500)}ms (threshold 1000ms).`,
  () => `High CPU load detected: ${randInt(80, 96)}% over the last 60s.`,
  () => `Retrying request to ${pick(SERVICES)} (attempt ${randInt(2, 3)}/5) after ${randInt(200, 900)}ms delay.`,
  () => `Disk usage at ${randInt(82, 94)}% on /var/log.`,
  () => `Connection pool nearly exhausted for ${pick(DATABASES)}: ${randInt(17, 19)}/20 in use.`,
  () => `Rate limit approaching for client 10.0.${randInt(0, 255)}.${randInt(1, 254)}: ${randInt(85, 99)}% of quota used.`,
  () => `Response time from ${pick(SERVICES)} degraded: p95 ${randInt(700, 1800)}ms.`,
  () => `Request to ${pick(ENDPOINTS)} throttled with status 429, retry after ${randInt(1, 30)}s.`,
  () => `Cache hit ratio dropped to ${randInt(35, 60)}%.`,
  () => `Deprecated API called: ${pick(METHODS)} ${pick(ENDPOINTS)} (use /api/v2 instead).`,
];

const ERROR_MESSAGES = [
  () => `API network request to ${pick(ENDPOINTS)} failed with status ${pick(ERROR_CODES)}.`,
  () => `Database query to ${pick(DATABASES)} timed out after ${randInt(5, 30)}s.`,
  () => `Unhandled exception in worker ${randInt(1, 8)}: TypeError: Cannot read properties of undefined.`,
  () => `Connection to ${pick(SERVICES)} refused (ECONNREFUSED 10.0.${randInt(0, 255)}.${randInt(1, 254)}:${pick([5432, 6379, 8080, 9200])}).`,
  () => `Upstream ${pick(SERVICES)} unavailable: received status ${pick([502, 503, 504])}.`,
  () => `Failed to write to disk: no space left on device (${pick(['/var/log', '/data', '/tmp'])}).`,
  () => `Out of memory: process killed at ${randInt(97, 100)}% heap usage.`,
  () => `Payment transaction txn_${randInt(100000, 999999)} failed: gateway returned status ${pick(ERROR_CODES)}.`,
  () => `Job ${pick(JOBS)} crashed after ${randInt(1, 45)}s with exit code ${randInt(1, 137)}.`,
  () => `TLS handshake with ${pick(SERVICES)} failed: certificate has expired.`,
];

const POOLS = {
  INFO: INFO_MESSAGES,
  WARN: WARN_MESSAGES,
  ERROR: ERROR_MESSAGES,
};

// ---- Public API -------------------------------------------------------------

/** Weighted random level: INFO 60%, WARN 25%, ERROR 15%. */
function pickLevel() {
  const roll = Math.random() * 100;
  for (const { level, upTo } of WEIGHTS) {
    if (roll < upTo) return level;
  }
  return 'INFO'; // unreachable safeguard
}

/**
 * Generate one mock log entry.
 * @param {Date} [now] optional clock override (useful for tests)
 * @returns {{level: string, timestamp: string, message: string, line: string}}
 */
function generateLog(now = new Date()) {
  const level = pickLevel();
  const timestamp = formatTimestamp(now);
  const message = pick(POOLS[level])();
  return { level, timestamp, message, line: `[${level}] ${timestamp} - ${message}` };
}

module.exports = { generateLog, formatTimestamp, pickLevel, LEVELS };
