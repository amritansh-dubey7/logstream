# LogStream

A single-page **developer observability dashboard** that behaves like a live terminal inspector.
The Node.js backend pushes one mock log line every 500 ms to each connected browser over
**Server-Sent Events (SSE)**. No polling, no database, one dependency (`express`), no build step.

## Features

**Core**

- Control panel: `Name / Client ID` input, `[ Start Stream ]`, `[ Stop Stream ]` (disabled until streaming).
- Dark, monospaced terminal that is completely blank on load. Start fills it every 500 ms; Stop freezes it instantly.
- Mock log engine: random `[INFO]` / `[WARN]` / `[ERROR]` lines (60 / 25 / 15 %), `HH:MM:SS.mmm` timestamps,
  and messages that match their level. Example:
  `[ERROR] 11:42:02.500 - API network request to /api/v1/users failed with status 500.`
- Native `EventSource` on the client. There is no `setInterval` anywhere in the frontend.
- Per-connection timers on the server, cleared on every disconnect path (Stop, tab close, crash, network drop).
- Fully isolated sessions: concurrent tabs and `curl`s never share timers, buffers or lines.
- Rolling window: the DOM never holds more than 100 rows.

**Bonus (all three)**

- **B1** level filter (`All Logs`, `Info Only`, `Warnings Only`, `Errors Only`) that filters live without closing the connection.
- **B2** `[ Save Session Output ]` downloads exactly the rows on screen as `logs.txt`.
- **B3** custom log injection: a collapsible panel on the dashboard (sends to your own session) and a standalone
  portal at `/inject.html` (target a sessionId, a client name, or everyone).

**Hardening**

`clientId` sanitization, a 100-session cap (`503`), backpressure handling, graceful shutdown,
clean `404` / `400` / `500` responses, XSS-safe rendering, bfcache-safe page lifecycle.

## Requirements

- Node.js 16 or newer (developed and tested on Node 22)
- npm
- For the test scripts: `bash`, `curl` (on Windows use Git Bash or WSL)

## Setup

```bash
unzip logstream-final.zip && cd logstream   # or: git clone <your-repo-url> logstream && cd logstream
npm install
npm start
```

Expected output:

```
[LogStream] listening on http://localhost:3000
```

Open <http://localhost:3000>. Use another port with `PORT=4000 npm start`.

## Architecture

```
  Browser tab (one per user)                          Node.js process (server.js)
 +------------------------------+                  +--------------------------------------------+
 | index.html / style.css       |   GET /stream    |  express.static(public/)                   |
 | app.js                       | ---------------> |                                            |
 |  - EventSource (native SSE)  |                  |  GET /stream  (one closure per request)    |
 |  - allLines buffer (500)     | <--------------- |    sessionId = crypto.randomUUID()         |
 |  - terminal DOM (100 rows)   |  event: session  |    timer     = setInterval(tick, 500)      |
 |  - filter (B1) / save (B2)   |  event: log      |    heartbeat = setInterval(ping, 15000)    |
 |                              |  event: injected |    cleanup() on req close / res close /    |
 |  inject panel (B3)           |  : ping          |               res error / failed write     |
 |                              |                  |                                            |
 |  POST /api/inject ---------> | ---------------> |  POST /api/inject                          |
 +------------------------------+                  |    rate limit -> parse -> validate         |
                                                   |    resolve target -> res.write(injected)   |
 inject.html (portal)  ---------------------------> |    (no new timer, log loop untouched)      |
 curl -N /stream       ---------------------------> |                                            |
                                                   |  GET /api/debug/sessions                   |
                                                   |                                            |
                                                   |  sessionManager (Map: sessionId -> session)|
                                                   |    add / remove / get / findByClientId /   |
                                                   |    all / count / closeAll                  |
                                                   |    remove() also clears that session's     |
                                                   |    timers, so nothing can leak             |
                                                   |                                            |
                                                   |  logEngine.generateLog()  (pure, no HTTP)  |
                                                   +--------------------------------------------+
```

**How isolation and cleanup work**

- Every `/stream` request creates its own `sessionId` and its own two timers inside the request handler.
  There is no shared timer, shared buffer or shared generator state.
- `clientId` is a display label only. Two tabs may use the same name and still get separate sessions.
- A disconnect is caught on `req 'close'`, `res 'close'` and `res 'error'`. All three call one idempotent
  `cleanup()`, which calls `sessionManager.remove()`, which clears that session's timers.
- Every write goes through a guard: if the response is ended or destroyed, the session is cleaned up instead.
- Backpressure: if `res.write()` returns `false`, ticks are skipped until `drain`; after 10 skipped ticks (5 s)
  the socket is destroyed and the session removed.

## API

| Method | Path | Description |
|---|---|---|
| GET | `/stream?clientId=<string>` | SSE stream. `session` event once, an immediate first `log`, then a `log` every 500 ms, `injected` events on demand, a `: ping` comment every 15 s. `503` when 100 sessions are active or the server is shutting down. |
| POST | `/api/inject` | Body `{ "message": string, "target": "<sessionId> / <clientId> / all" }`. Returns `200 {delivered:N}`, `400` invalid, `404` no such target, `429` rate limited. |
| GET | `/api/debug/sessions` | `{ active, sessions:[{sessionId,clientId,startedAt}], memory:{rss,heapUsed} }` |
| GET | `/`, `/inject.html`, `/style.css`, `/app.js` | Static files from `public/`. Anything else is a clean `404`. |

**SSE events**

| Event | `data` | Notes |
|---|---|---|
| `session` | `{"sessionId":"<uuid>","clientId":"<sanitized>"}` | Sent once, first |
| `log` | `{"level","timestamp","message","line"}` | `line` is `[LEVEL] HH:MM:SS.mmm - message` |
| `injected` | same shape, `level: "CUSTOM"` | Delivered through the target's existing response |
| `: ping` | (comment) | Every 15 000 ms, keeps proxies from closing idle streams |

Response headers on `/stream`: `Content-Type: text/event-stream`, `Cache-Control: no-cache, no-transform`,
`Connection: keep-alive`, `X-Accel-Buffering: no`.

**`POST /api/inject` details**

| Status | When |
|---|---|
| `200` | delivered to at least one session |
| `400` | malformed JSON, body over 1 kb, wrong Content-Type, `message` missing, not a string, empty after cleaning or over 200 chars, `target` missing or blank |
| `404` | no active session matches the target |
| `429` | more than 10 requests from one IP in a 10 s window (`Retry-After` header included) |

Messages have every control character (`\r`, `\n`, tab, NUL, U+2028/2029...) replaced by a space before
trimming, so a message can never forge an extra SSE event.

## Requirement checklist

Results are from the final Phase 9 code, run in a Linux sandbox with Node 22.
**Real-browser rendering was not tested by the author** (no browser in the build sandbox). Frontend rows
marked *jsdom* were run against the real `index.html` and `app.js` in jsdom (a DOM simulator) over real SSE
against the real server. Run the manual browser checklist below on your machine before you rely on those rows.

### Mandatory

| # | Requirement | How to test | Expected | Result |
|---|---|---|---|---|
| M1 | Control panel | Open the page | Name input, Start enabled, Stop disabled | PASS (jsdom) |
| M2 | Dark mono terminal, blank on load | Open the page; `document.getElementById('terminal').children.length` | Black (`#000`) monospace box, `0` rows, no text | PASS (jsdom: 0 rows, empty text). Colors by CSS review; visual check manual |
| M3 | Start streams every 500 ms, Stop freezes | Start, wait 3 s; Stop, wait 2 s | About 7 rows after 3.2 s; row count and text unchanged after Stop | PASS (jsdom: 7 rows, frozen) |
| M4 | Log engine format | `node -e "const {generateLog}=require('./logEngine');for(let i=0;i<20;i++)console.log(generateLog().line)"` | `[LEVEL] HH:MM:SS.mmm - message`, ms zero-padded | PASS (200 000 generated lines, 0 malformed; `09:05:03.007` for 7 ms) |
| M5 | Level weights and matching messages | Same engine, 200 000 samples | INFO 60 %, WARN 25 %, ERROR 15 %; INFO benign, WARN degraded, ERROR failures | PASS (60.3 / 24.9 / 14.8 %; pools reviewed by reading) |
| M6 | SSE with native `EventSource`, no polling | `grep -n setInterval public/*` | No matches; DevTools Network shows one `stream` request | PASS (grep: none; jsdom run used `EventSource`) |
| M7 | First log immediately, then every 500 ms | `curl -N "localhost:3000/stream?clientId=a"` | `session`, then a `log` at once, then one per 500 ms | PASS (gaps 485, 502, 501, 500, 500 ms) |
| M8 | Button state | Start, then Stop | Streaming: Start disabled. Stopped: Stop disabled | PASS (jsdom, both transitions immediate) |
| M9 | Server detects stop / tab close, clears timers | `curl -N` then Ctrl+C; `curl -s localhost:3000/api/debug/sessions` | `active: 0` within about 1 s; timers cleared | PASS (`npm test`: released in 33-38 ms; live timers = baseline + 2 x active at every step) |
| M10 | Session isolation | Two or more concurrent `curl -N` with different IDs | Different `sessionId`s; no line shared; killing one leaves the others streaming | PASS (`npm test` 62 / 62; live run: 2 sessions, an inject to `tabA` reached only `tabA`) |
| M11 | Rolling window of 100 rows | Let a tab run 60 s; read `children.length` | Never above 100 | PASS (jsdom: reached 100, never above) |

### Bonus

| # | Requirement | How to test | Expected | Result |
|---|---|---|---|---|
| B1 | Filter live, connection stays open | Choose Errors Only while streaming; check `/api/debug/sessions` | Only `[ERROR]` (and your injected `[CUSTOM]`) rows; same `sessionId`, one session | PASS (jsdom: same `sessionId` before and after; in this short run the filtered view held only the injected row, so level content was not exercised here. The Phase 7 jsdom suite, which is not shipped, covered it) |
| B2 | Save Session Output | Click Save | `logs.txt` with exactly the rows on screen, joined by `\n`; disabled when empty | PASS (jsdom: filename `logs.txt`, content equals the screen) |
| B3 | Custom log injection | Dashboard panel, or `curl -X POST ... /api/inject` | `200 {"delivered":1}`; one cyan row appears; log cadence unchanged | PASS (curl: `tabA` delivered 1, `all` delivered 2, no row duplicated; jsdom: exactly one row) |
| B3b | Injection validation and limits | Bad target, malformed JSON, blank message, 12 rapid posts | `404`, `400`, `400`, then `429` after the tenth | PASS (`404`, `400`, `400`; sequence `200 x10, 429, 429`) |

### Phase 9 edge cases (`npm run test:hardening`, 51 / 51)

| # | Requirement | How to test | Expected | Result |
|---|---|---|---|---|
| 1 | `clientId` sanitization | 10 inputs: empty, symbols, 50 chars, HTML, non-Latin, CRLF, repeated and array params | Max 30 chars, letters / digits / space / `-_`, fallback `anonymous` | PASS |
| 2 | `MAX_SESSIONS` cap | Open 100 streams, then a 101st | `503` JSON plus `Retry-After`; a freed slot admits a new stream; timers = base + 2 x sessions | PASS |
| 3 | Graceful shutdown | `SIGTERM` and `SIGINT` with live streams | Exit code 0, every curl ended cleanly, no timers, port closed | PASS (also live: exit 0, curl exit 0) |
| 4 | Backpressure | A client that never drains; one that drains after a `false` | Stuck client skipped, then dropped after 10 ticks; recovering client keeps streaming | PASS (simulated `write()` result, see limitations) |
| 5 | Reconnect storm | 400 connect / abort cycles, 40 at once, same name | No duplicate sessionIds, `active` 0, timers at baseline, each open closed once | PASS |
| 6 | Memory stays flat | 2 500 sessions, `heapUsed` after forced GC | Growth under 5 MB | PASS (7 966 KB to 8 655 KB, +688 KB) |
| 7 | XSS | `<img src=x onerror=alert(1)>` as client ID and as injected message | Plain text, no element, no alert | PASS (server side and jsdom; a real browser run is on the manual list) |
| 8 | Refresh and back / forward cache | Refresh, navigate away and Back, close the tab | Old session gone within about 1 s; UI resets to Stopped after a bfcache restore | PASS static (`beforeunload`, `pagehide`, `pageshow` handlers present; vanished clients covered by 4 and 5). Browser part manual |
| 9 | Clean 404, no crash | Unknown route, unknown `/api/` route, malformed JSON, bad percent-encoding, path traversal | Clean `4xx`, process alive, no stack traces | PASS |

### Also checked

| Requirement | How to test | Expected | Result |
|---|---|---|---|
| SSE headers per contract | `curl -s -i -N --max-time 2 "localhost:3000/stream?clientId=a"` | `text/event-stream`, `no-cache, no-transform`, `keep-alive`, `X-Accel-Buffering: no` | PASS |
| Heartbeat | `curl -s -N --max-time 16 ... \| grep -c '^: ping'` | `1` | PASS |
| `HEAD /stream` does not leak | `curl -sI localhost:3000/stream`, then the debug route | `active: 0` | PASS |
| Same name in two tabs | Two streams with one `clientId` | Two sessions, distinct `sessionId`s | PASS (`npm test`) |

## Commands reviewers are likely to run

Start the server first: `npm start`. On Windows PowerShell use `curl.exe` instead of `curl`.

```bash
# 1. Stream, then Ctrl+C
curl -N "http://localhost:3000/stream?clientId=a"

# 2. Is the session gone?
curl -s http://localhost:3000/api/debug/sessions
# -> {"active":0,"sessions":[],"memory":{...}}

# 3. Headers only (stops after 2 s)
curl -s -i -N --max-time 2 "http://localhost:3000/stream?clientId=a"

# 4. Concurrent sessions (two terminals, or the & form)
curl -s -N "localhost:3000/stream?clientId=alpha" > /tmp/alpha.out &
curl -s -N "localhost:3000/stream?clientId=bravo" > /tmp/bravo.out &
sleep 2; curl -s localhost:3000/api/debug/sessions     # active: 2, two different sessionIds
kill %1; sleep 1; curl -s localhost:3000/api/debug/sessions   # active: 1
kill %2

# 5. Inject (B3)
curl -s -X POST localhost:3000/api/inject -H "Content-Type: application/json" \
  -d '{"message":"hello from curl","target":"alpha"}'     # {"delivered":1}
curl -s -X POST localhost:3000/api/inject -H "Content-Type: application/json" \
  -d '{"message":"to everyone","target":"all"}'
curl -s -w ' [%{http_code}]\n' -X POST localhost:3000/api/inject -H "Content-Type: application/json" \
  -d '{"message":"x","target":"nobody"}'                  # 404

# 6. Unknown route
curl -i localhost:3000/nope                               # 404 Not Found
```

**Leak check** (20 abrupt client deaths, like closing 20 tabs at once):

```bash
curl -s localhost:3000/api/debug/sessions; echo                 # baseline, active: 0
pids=()
for i in $(seq 1 20); do
  curl -s -N --max-time 60 "localhost:3000/stream?clientId=leak$i" > /dev/null &
  pids+=($!)
done
sleep 1
curl -s localhost:3000/api/debug/sessions | head -c 40; echo    # active: 20
kill -9 "${pids[@]}" 2>/dev/null                                # abrupt client death
sleep 1
curl -s localhost:3000/api/debug/sessions; echo                 # active: 0, heapUsed about where it started
```

`active` only counts the session map. A timer that outlived its session would not show up there, so
`npm test` also counts live `setInterval` handles through a preload probe and asserts
`timers == baseline + 2 x active` after every step.

## Testing

```bash
npm test                         # concurrency and leak test, 62 checks, about 12 s (own server on port 3100)
npm run test:hardening           # Phase 9 edge cases, 51 checks, about 16 s (own server on port 3300)
LONG=1 npm run test:hardening    # longer memory soak (12 000 sessions)
LOGSTREAM_URL=http://localhost:3000 bash test/smoke.sh   # test a server you already started (timer checks skipped)
```

Both scripts start their own server, print PASS / FAIL per check, and stop it. They need `bash`, `curl`
and `node` only (no `jq`). The timer probe and the backpressure simulation are generated at run time
and are not part of the runtime code.

During Phases 6 and 9, both scripts were mutation-tested against deliberately broken copies of the server (a
heartbeat timer not cleared, missing close handlers, non-idempotent cleanup, a shared log generator, no session
cap, no backpressure drop, `closeAll()` removed from shutdown), and each one failed the matching check. That was
not repeated in this final pass; the final pass re-ran both scripts unchanged (62 / 62 and 51 / 51).

### Manual browser checklist

Keep <http://localhost:3000/api/debug/sessions> open in a second tab (press F5 to refresh it).

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Open the page | Dark page, black empty terminal, Stop disabled, Save disabled | |
| 2 | Start, wait 5 s | Colored lines about every 500 ms (green INFO, yellow WARN, red ERROR) | |
| 3 | Let it run 60 s; console: `document.getElementById('terminal').children.length` | Never above 100 | |
| 4 | Stop | Screen freezes at once; Start enabled, Stop disabled; debug shows `active: 0` within about 1 s | |
| 5 | Open 3 tabs (`dev`, `dev`, `qa`), Start all | `active: 3`, three distinct `sessionId`s, lines differ per tab | |
| 6 | Close one tab | `active` drops by one within about 1 s | |
| 7 | Streaming tab: press F5 | Old session gone; a new one only after you click Start | |
| 8 | Streaming tab: navigate away, press Back | Page shows Stopped; Start works; one session only | |
| 9 | Choose Errors Only while streaming | Only red lines; same `sessionId` in the debug tab; Network tab shows no new `stream` request | |
| 10 | Click Save | `logs.txt` downloads and matches the screen | |
| 11 | Inject `<img src=x onerror=alert(1)>` | Cyan row with the literal text, no alert | |
| 12 | Client name `<img src=x onerror=alert(1)>`, Start | Name falls back to `anonymous`; no alert | |
| 13 | Ctrl+C in the server terminal with a tab streaming | Server prints `ended 1 session(s)` and exits; the tab shows "Connection lost, reconnecting..." | |
| 14 | DevTools Network | No repeating `fetch` / XHR; one `stream` connection per tab | |

## Design decisions

| Decision | Reason |
|---|---|
| Express 5, CommonJS, no build step, one dependency | Smallest surface; runs with `npm start` |
| SSE instead of WebSockets | The data flows one way; `EventSource` gives reconnects and needs no client library |
| All per-connection state lives in the `/stream` handler closure | Isolation by construction: nothing shared means nothing can bleed |
| `sessionManager.remove()` clears the timers | Every removal path (close, error, guard, shutdown) is leak-proof, because none can forget the timers |
| Three close hooks plus a write guard, one idempotent `cleanup()` | Detects every way a client can vanish; double calls are harmless |
| `MAX_SESSIONS` checked first, before allocating anything | A flood of rejected requests cannot leak timers or listeners |
| Backpressure drops after 10 skipped ticks and uses `res.destroy()` | Memory per client stays bounded; a stalled client never flushes a graceful `end()` |
| Injection writes one frame to the target's existing response | No new timer, so the 500 ms cadence is unchanged and the leak check (`2 x active`) still holds |
| The sender's tab does not append its injected line locally | The line returns over its own SSE stream, so it cannot appear twice and keeps arrival order |
| Control characters become spaces, then trim, then the length check | Blocks forged SSE events while keeping words apart |
| Rate limiter runs before body parsing and prunes lazily (no timer) | Spam is cheap to reject; a cleanup `setInterval` would look like a leak |
| Raw 500-line client buffer plus a 100-row DOM window | The DOM drops old rows, so a filter change needs the buffer to bring them back |
| Save reads the terminal rows, not the buffer | Spec: "exactly the rows currently visible"; respects the active filter |
| `CUSTOM` lines pass every filter | A message you just sent must not vanish and look like a failed Send |
| `textContent` everywhere, no `innerHTML` | Log text and client names are never parsed as HTML |
| `pagehide` plus `beforeunload` plus a `pageshow` reset | `beforeunload` is unreliable on mobile and for the back / forward cache |
| `inject.html` keeps its script inline | The fixed layout has no second JS file, and `app.js` is bound to the dashboard's elements |
| Status text lives outside the terminal | The terminal is blank on load and only ever holds log lines |

## Known limitations

- **Single process, in-memory state.** Sessions and rate-limit buckets live in one Node process and are lost
  on restart. Restarting disconnects every stream (browsers reconnect with new sessions). Two instances behind
  a load balancer would not see each other's sessions.
- **The session cap is global, not per IP.** One client can use all 100 slots.
- **Silent dead peers are detected late.** A client that disappears without a FIN / RST (a pulled cable) is
  found when a write fails or backpressure triggers, or when the OS TCP keepalive fires. A normal tab close,
  Stop, or killed `curl` is detected within milliseconds.
- **Backpressure is simulated in the test.** The logic uses Node's documented `write()` / `drain` behavior,
  but no real stalled socket was used (that needs megabytes of unread data).
- **`uncaughtException` is logged and ignored** so a demo stays up. Production practice is to log and restart
  under a supervisor, because state may be inconsistent afterwards.
- **Rate limit** is per process, a fixed window (a burst of up to 20 across a window edge), and keyed on the
  socket address (behind a reverse proxy that is the proxy's address, since `trust proxy` is not set).
- **`all` is a reserved target.** A client literally named `all` can only be targeted by `sessionId`.
- **Injected lines are not stored.** They are not replayed after a reconnect or a refresh. After a dropped
  connection the browser reconnects with a new session; a Send in that gap can return `404`, and the message
  stays in the box to resend.
- **Client-side limits.** Filters work on the last 500 lines received. Save exports the rendered rows (at most
  100). The terminal is not cleared on Stop / Start, so a restarted stream appends to the old lines.
- **Injection ignores backpressure** (one extra frame per request, bounded by the rate limit).
- Timestamps use the server's local time zone.
- **Not verified in a real browser by the author** (see the manual checklist). Browser-specific behavior such as
  download naming (`logs (1).txt`) and bfcache details may differ.

## What I would improve next

1. **Server-side filtering:** `/stream?level=ERROR` so filtered tabs stop receiving lines they hide, and filters
   work on full history instead of the last 500 lines.
2. **Authentication and authorization:** a token on `/stream` and `/api/inject`, targets scoped to the caller's
   own sessions, and no session list on an unauthenticated debug route.
3. **Pub/sub for multi-server scaling:** put the log source and injected messages on Redis (or NATS) channels so
   any instance can deliver to any session, with sticky routing or a shared session registry.
4. **Resume after reconnect:** event IDs plus a small per-session ring buffer so `Last-Event-ID` replays missed
   lines (including injected ones).
5. **Per-IP session limits** and a proper sliding-window rate limiter.
6. **Observability for the observer:** a metrics endpoint (active sessions, dropped sessions, write latency)
   and structured JSON logs.
7. **Real-browser tests in CI** (Playwright) for the bfcache, download and XSS rows that are manual today.
8. A **Clear** button and a Pause that keeps receiving into the buffer.

## Project layout

```
logstream/
├── package.json        # scripts + single dependency (express)
├── server.js           # Express app: static files, /stream, /api/inject, /api/debug/sessions, shutdown
├── logEngine.js        # mock log generator, pure module
├── sessionManager.js   # active SSE session registry
├── public/
│   ├── index.html      # dashboard: controls, toolbar (filter, save), terminal, inject panel
│   ├── inject.html     # standalone injection portal
│   ├── style.css       # dark terminal theme, level colors, responsive layout
│   └── app.js          # EventSource, rolling window, filter (B1), save (B2), inject (B3)
├── test/
│   ├── smoke.sh        # concurrency and leak test (npm test)
│   └── hardening.sh    # Phase 9 edge cases (npm run test:hardening)
└── README.md
```

Contract constants: `PORT=3000` (env override), `LOG_INTERVAL_MS=500`, `HEARTBEAT_MS=15000`, `MAX_LINES=100`,
`BUFFER_MAX=500`, `MAX_SESSIONS=100`, `CLIENT_ID_MAX=30`, `INJECT_MAX_CHARS=200`.

## References and credits

No third-party source code has been copied into this project. These official documents guided the design:

- Express (OpenJS Foundation / Express.js contributors) - <https://expressjs.com/> and <https://github.com/expressjs/express>
- Express, `express.static`, `express.json()` and error handling - <https://expressjs.com/en/starter/static-files.html>, <https://expressjs.com/en/api.html#express.json>, <https://expressjs.com/en/guide/error-handling.html>
- `body-parser` error types (`entity.too.large`, `entity.parse.failed`) - <https://github.com/expressjs/body-parser>
- MDN Web Docs, *Using server-sent events* - <https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events>
- WHATWG HTML Living Standard, *Server-sent events* (including *Parsing an event stream*, which is why a newline in `data` can forge an event) - <https://html.spec.whatwg.org/multipage/server-sent-events.html>
- MDN Web Docs, *EventSource*, *Page Lifecycle API* (`pageshow`, bfcache), *Fetch API*, *`<details>`*, ARIA *`log`* role and `aria-live`, CSS `:focus-visible`, *`Retry-After`* and *429 Too Many Requests*
  (all under <https://developer.mozilla.org/>)
- Node.js documentation (`http` / `net` `write()` and `drain`, `crypto.randomUUID`, `-r/--require`, `--experimental-eventsource`) - <https://nodejs.org/docs/latest/api/>
- jsdom, used only for the author's scratch-folder frontend checks and not a dependency of this project - <https://github.com/jsdom/jsdom>
- curl manual (`-N`, `--max-time`) - <https://curl.se/docs/manpage.html>

## License

MIT
