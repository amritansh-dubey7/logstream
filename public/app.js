/**
 * app.js - LogStream frontend (Phase 5 streaming, Phase 7 bonuses B1 + B2, Phase 8 bonus B3, Phase 9 pagehide).
 *
 * Owns: Start/Stop wiring, EventSource lifecycle, the rolling terminal window,
 * smart autoscroll, SSE error/reconnect status, the live level filter (B1),
 * "Save Session Output" (B2) and the "Inject custom log" panel (B3).
 *
 * Data flow for log lines:
 *   SSE 'log' / 'injected' event -> allLines (raw buffer, max BUFFER_MAX)
 *                                -> terminal DOM (only if the line matches the current
 *                                   filter, max MAX_LINES rows)
 * The filter only decides what is RENDERED. It never touches the EventSource,
 * so changing it does not close or reopen the connection.
 *
 * B3: Send does POST /api/inject {message, target: <my sessionId>}. The new line is NOT
 * appended locally: the server delivers it back through this tab's own open SSE stream as an
 * 'injected' event, so it appears once, in order with the other lines, and cannot be duplicated.
 */
'use strict';

// ---- Constants ----------------------------------------------------------
const MAX_LINES = 100; // rolling DOM window (contract)
const BUFFER_MAX = 500; // raw client-side buffer used to re-render on filter change (contract)
const CLIENT_ID_PATTERN = /^[A-Za-z0-9 _-]{1,30}$/; // 1-30 chars, letters/digits/space/-/_
const DEFAULT_CLIENT_ID = 'anonymous';
const NEAR_BOTTOM_PX = 24; // "close enough to bottom" for autoscroll
const VALID_FILTERS = ['ALL', 'INFO', 'WARN', 'ERROR'];
const SAVE_FILENAME = 'logs.txt';
const REVOKE_DELAY_MS = 1000; // let the browser start the download before freeing the blob URL
const INJECT_MAX_CHARS = 200; // contract: INJECT_MAX_CHARS (the input also has maxlength=200)
const INJECT_IDLE_HINT = 'Start a stream to enable injection.';

// ---- Elements -------------------------------------------------------------
const clientIdInput = document.getElementById('clientId');
const startBtn = document.getElementById('startBtn');
const stopBtn = document.getElementById('stopBtn');
const statusEl = document.getElementById('status');
const terminalEl = document.getElementById('terminal');
const levelFilterEl = document.getElementById('levelFilter');
const saveBtn = document.getElementById('saveBtn');
const injectMessageEl = document.getElementById('injectMessage');
const injectSendBtn = document.getElementById('injectSend');
const injectStatusEl = document.getElementById('injectStatus');

// ---- State ------------------------------------------------------------
let eventSource = null;
let streaming = false;
let currentSessionId = null;
let injectInFlight = false; // one inject request at a time
let allLines = []; // raw entries { level, text }, oldest first, capped at BUFFER_MAX
let currentFilter = normalizeFilter(levelFilterEl.value);

// ---- Helpers ----------------------------------------------------------------

/** Trim + validate the client id. Invalid input falls back to "anonymous" (never silently stripped). */
function resolveClientId(raw) {
  const trimmed = (raw || '').trim();
  if (!trimmed) return DEFAULT_CLIENT_ID;
  return CLIENT_ID_PATTERN.test(trimmed) ? trimmed : DEFAULT_CLIENT_ID;
}

function setStatus(text) {
  statusEl.textContent = text;
}

function setInjectStatus(text) {
  injectStatusEl.textContent = text;
}

/** True when the user is already near the bottom (or the terminal is empty/short). */
function isNearBottom() {
  const distance = terminalEl.scrollHeight - terminalEl.scrollTop - terminalEl.clientHeight;
  return distance <= NEAR_BOTTOM_PX;
}

/** Map a server level to its CSS class; anything unrecognized renders as a system line. */
function levelClassFor(level) {
  switch (level) {
    case 'INFO': return 'log-info';
    case 'WARN': return 'log-warn';
    case 'ERROR': return 'log-error';
    case 'CUSTOM': return 'log-custom';
    default: return 'log-system';
  }
}

/** Anything that is not a known filter value becomes "ALL". */
function normalizeFilter(value) {
  return VALID_FILTERS.includes(value) ? value : 'ALL';
}

/**
 * Does a line with this level belong in the terminal under the current filter?
 * CUSTOM (injected) lines are always shown: hiding a message the user just
 * sent would look like the Send button failed.
 */
function matchesFilter(level) {
  if (currentFilter === 'ALL') return true;
  if (level === 'CUSTOM') return true;
  return level === currentFilter;
}

/** Save is only possible when there is something on screen to save. */
function syncSaveButton() {
  saveBtn.disabled = terminalEl.children.length === 0;
}

// ---- Buffer + rendering -----------------------------------------------------------

/** Remember a raw line (every received line, matching or not), oldest dropped past BUFFER_MAX. */
function bufferLine(entry) {
  allLines.push(entry);
  if (allLines.length > BUFFER_MAX) {
    allLines.splice(0, allLines.length - BUFFER_MAX);
  }
}

/** Build one terminal row (textContent only, so log text is never parsed as HTML). */
function createLineElement(entry) {
  const row = document.createElement('div');
  row.className = `log-line ${levelClassFor(entry.level)}`;
  row.textContent = entry.text;
  return row;
}

/** Append one row to the live terminal, trim to MAX_LINES, keep smart autoscroll. */
function appendLine(entry) {
  const stickToBottom = isNearBottom();

  terminalEl.appendChild(createLineElement(entry));

  // Rolling window: never keep more than MAX_LINES rows in the DOM.
  while (terminalEl.children.length > MAX_LINES) {
    terminalEl.removeChild(terminalEl.firstChild);
  }

  if (stickToBottom) {
    terminalEl.scrollTop = terminalEl.scrollHeight;
  }
  syncSaveButton();
}

/** Rebuild the terminal from the buffer: the last MAX_LINES lines matching the current filter. */
function renderFiltered() {
  const visible = [];
  for (let i = allLines.length - 1; i >= 0 && visible.length < MAX_LINES; i -= 1) {
    if (matchesFilter(allLines[i].level)) visible.push(allLines[i]);
  }
  visible.reverse();

  const fragment = document.createDocumentFragment();
  for (const entry of visible) fragment.appendChild(createLineElement(entry));

  terminalEl.textContent = ''; // empties the terminal (no HTML parsing involved)
  terminalEl.appendChild(fragment);
  terminalEl.scrollTop = terminalEl.scrollHeight; // the whole view changed: show the newest rows
  syncSaveButton();
}

// ---- B1: level filter ----------------------------------------------------------------

/**
 * Switch the active filter. Works while streaming, stopped, and with an empty
 * buffer. Also used to re-sync after the browser restores a stale <select> value.
 */
function applyFilter(value) {
  const next = normalizeFilter(value);
  levelFilterEl.value = next; // control always mirrors state, even for an invalid value
  if (next === currentFilter) return;
  currentFilter = next;
  renderFiltered();
}

// ---- B2: save session output ----------------------------------------------------------

/** Download exactly the rows currently visible in the terminal as logs.txt. */
function saveSessionOutput() {
  const rows = terminalEl.children;
  if (rows.length === 0) return; // nothing on screen (the button is disabled in this case)

  try {
    const text = Array.from(rows, (row) => row.textContent).join('\n');
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain;charset=utf-8' }));

    const link = document.createElement('a');
    link.href = url;
    link.download = SAVE_FILENAME;
    link.hidden = true;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);

    setTimeout(() => URL.revokeObjectURL(url), REVOKE_DELAY_MS);
  } catch (_err) {
    setStatus('[SYSTEM] Could not save the session output.');
  }
}

// ---- B3: inject custom log -----------------------------------------------------------

/**
 * Injection is only possible into a live session of this tab: the stream must be running
 * AND the server must have told us our sessionId (the 'session' event). The message box
 * follows that; Send additionally waits while a request is in flight.
 */
function syncInjectUi() {
  const canInject = streaming && currentSessionId !== null;
  injectMessageEl.disabled = !canInject;
  injectSendBtn.disabled = !canInject || injectInFlight;
}

/** Turn a failed /api/inject response into one short status line. */
function describeInjectFailure(status, body, retryAfterHeader) {
  const serverMessage = body && typeof body.error === 'string' ? body.error : '';
  if (status === 429) {
    const seconds = Number(retryAfterHeader) || (body && body.retryAfterSeconds) || 10;
    return `[SYSTEM] Too many injections. Try again in ${seconds}s.`;
  }
  if (status === 404) return '[SYSTEM] Your session is no longer active on the server.';
  if (status === 400) return `[SYSTEM] Rejected: ${serverMessage || 'invalid message'}.`;
  return `[SYSTEM] Injection failed (HTTP ${status}).`;
}

async function sendInjection() {
  if (!streaming || currentSessionId === null || injectInFlight) return; // double-submit guard

  const message = injectMessageEl.value.trim();
  if (!message) {
    setInjectStatus('Type a message first.');
    return;
  }
  if (message.length > INJECT_MAX_CHARS) {
    setInjectStatus(`[SYSTEM] Message is longer than ${INJECT_MAX_CHARS} characters.`);
    return;
  }

  injectInFlight = true;
  syncInjectUi();
  setInjectStatus('Sending...');

  try {
    const response = await fetch('/api/inject', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ message, target: currentSessionId }),
    });
    const body = await response.json().catch(() => null);

    if (response.ok) {
      // Don't clobber text the user kept typing while the request was in flight.
      if (injectMessageEl.value.trim() === message) injectMessageEl.value = '';
      setInjectStatus('Sent. It appears in the stream below.');
    } else {
      setInjectStatus(describeInjectFailure(response.status, body, response.headers.get('Retry-After')));
    }
  } catch (_err) {
    setInjectStatus('[SYSTEM] Could not reach the server.');
  } finally {
    injectInFlight = false;
    syncInjectUi();
  }
}

// ---- UI state ----------------------------------------------------------------

function setStreamingUi(isStreaming) {
  startBtn.disabled = isStreaming;
  stopBtn.disabled = !isStreaming;
  clientIdInput.disabled = isStreaming;
  syncInjectUi();
  if (!isStreaming) setInjectStatus(INJECT_IDLE_HINT);
}

// ---- SSE event handlers ----------------------------------------------------------------

function handleSessionEvent(event) {
  try {
    const data = JSON.parse(event.data);
    currentSessionId = data.sessionId;
    setStatus(`Streaming as "${data.clientId}" (session ${data.sessionId.slice(0, 8)})`);
    syncInjectUi(); // sessionId known: injection can be enabled
    if (!injectInFlight) setInjectStatus('Ready. Messages go to your session.');
  } catch (_err) {
    // Malformed session payload is not fatal - the log stream still works.
  }
}

/**
 * Shared by 'log' and 'injected' events: both carry { level, timestamp, message, line }.
 * Buffer first (every line), render only if it matches the filter.
 */
function handleLineEvent(event) {
  if (!streaming) return; // guard: nothing in-flight appends after Stop
  try {
    const data = JSON.parse(event.data);
    if (typeof data.line !== 'string') return;
    const entry = { level: String(data.level), text: data.line };
    bufferLine(entry);
    if (matchesFilter(entry.level)) appendLine(entry);
  } catch (_err) {
    // Drop a malformed frame rather than crash the UI.
  }
}

function handleError() {
  if (!streaming) return; // Stop already closed the connection; ignore the resulting error
  if (eventSource && eventSource.readyState === EventSource.CONNECTING) {
    setStatus('[SYSTEM] Connection lost, reconnecting...');
  } else {
    // CLOSED: the browser gave up (for example the server answered 503 "too many streams").
    setStatus('[SYSTEM] Connection closed by the server. Click Stop, then Start to retry.');
  }
  // Button/input state is left exactly as-is: the stream is still "on" until the
  // user clicks Stop. This keeps the buttons honest about what the user asked
  // for instead of flipping them from a transient network error.
}

// ---- Start / Stop ----------------------------------------------------------------

function startStream() {
  if (streaming) return; // block double-start

  const clientId = resolveClientId(clientIdInput.value);
  clientIdInput.value = clientId;

  streaming = true;
  currentSessionId = null;
  setStreamingUi(true);
  setStatus('Connecting...');
  setInjectStatus('Connecting...');

  eventSource = new EventSource(`/stream?clientId=${encodeURIComponent(clientId)}`);
  eventSource.addEventListener('session', handleSessionEvent);
  eventSource.addEventListener('log', handleLineEvent);
  eventSource.addEventListener('injected', handleLineEvent);
  eventSource.addEventListener('error', handleError);
}

function stopStream() {
  if (!streaming) return; // block double-stop

  streaming = false; // flip BEFORE closing so any already in-flight message is dropped by the guard
  if (eventSource) {
    eventSource.close();
    eventSource = null;
  }
  currentSessionId = null;
  setStreamingUi(false);
  setStatus('Stopped');
}

// ---- Wiring ----------------------------------------------------------------

startBtn.addEventListener('click', startStream);
stopBtn.addEventListener('click', stopStream);
levelFilterEl.addEventListener('change', () => applyFilter(levelFilterEl.value));
saveBtn.addEventListener('click', saveSessionOutput);
injectSendBtn.addEventListener('click', sendInjection);
injectMessageEl.addEventListener('keydown', (event) => {
  // Enter sends; ignore Enter that confirms an IME composition (CJK input).
  if (event.key === 'Enter' && !event.isComposing) {
    event.preventDefault();
    sendInjection();
  }
});

// Tab/window closing: close the EventSource explicitly rather than rely on the
// browser, so the server's close handler fires as fast as possible.
window.addEventListener('beforeunload', () => {
  if (eventSource) eventSource.close();
});
// pagehide also fires when a page enters the back/forward cache and on mobile tab discards,
// where beforeunload is not reliable. (pageshow below resets the UI if the page comes back.)
window.addEventListener('pagehide', () => {
  if (eventSource) eventSource.close();
});

// Back/forward-cache restores can bring the page back with a dead EventSource
// object. Reset to a clean Stopped state so Start is reliable afterwards. Some
// browsers also restore a <select> value without firing "change", so re-sync
// the filter state from the control.
window.addEventListener('pageshow', (event) => {
  if (event.persisted && streaming) {
    stopStream();
  }
  applyFilter(levelFilterEl.value);
});

setStreamingUi(false);
setStatus('Idle');
syncSaveButton();
