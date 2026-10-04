#!/usr/bin/env bash
# hardening.sh - Phase 9 edge-case tests for LogStream.
#
#   bash test/hardening.sh            # about 40 s
#   LONG=1 bash test/hardening.sh     # longer memory soak (about 2 min)
#
# Starts its own server (TEST_PORT, default 3300) with a small preload that
#   - counts live setInterval handles   (leak check, same idea as smoke.sh)
#   - exposes GET /gc on PROBE_PORT     (forces a GC, returns heapUsed)
#   - simulates a client that stops reading (clientId "stuck") and one that
#     recovers (clientId "hiccup") for the backpressure test
# Nothing here is added to the project's runtime code. Needs: bash, curl, node.
#
# Item numbers match the Phase 9 list in LOGSTREAM_DEV_PROMPT.md.
#   1 sanitize  2 session cap  3 shutdown  4 backpressure  5 reconnect storm
#   6 memory    7 XSS         8 bfcache/refresh (static part)  9 404 + no crash

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PORT="${TEST_PORT:-3300}"
PROBE_PORT="${PROBE_PORT:-3301}"
SHUT_PORT="${SHUT_PORT:-3302}"
BASE="http://127.0.0.1:${TEST_PORT}"
DEBUG_URL="$BASE/api/debug/sessions"
PROBE_URL="http://127.0.0.1:${PROBE_PORT}"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t logstream-hardening)"
SERVER_PID=""
EXTRA_PIDS=()
PASS=0
FAIL=0

cleanup() {
  local p
  for p in "${EXTRA_PIDS[@]:-}"; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1 (expected $2, got $3)"; fi; }

# json_get <url> <js expression over d>
json_get() {
  curl -s --max-time 3 "$1" | node -e '
    let s = ""; process.stdin.on("data", (c) => (s += c)).on("end", () => {
      try { console.log(new Function("d", "return (" + process.argv[1] + ")")(JSON.parse(s))); }
      catch (e) { console.log("ERR"); }
    });' "$2"
}
active() { json_get "$DEBUG_URL" 'd.active'; }
timers() { json_get "$PROBE_URL/" 'd.liveIntervals'; }

# wait_for <description of check> <command...>: poll up to 8 s (every 100 ms) until the command succeeds
wait_for() {
  local i=0
  while [ "$i" -lt 80 ]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
active_is() { [ "$(active)" = "$1" ]; }
timers_are() { [ "$(timers)" = "$1" ]; }

# ---- preload: timer probe + gc + backpressure simulation -----------------------------
cat >"$TMP/probe.js" <<'EOF'
'use strict';
const http = require('http');
const live = new Set();
const origSet = global.setInterval;
const origClearInterval = global.clearInterval;
global.setInterval = function (...a) { const t = origSet.apply(this, a); live.add(t); return t; };
global.clearInterval = function (t) { live.delete(t); return origClearInterval.call(this, t); };

// Backpressure simulation. A real socket needs megabytes of unread data before write()
// returns false, so the test fakes the return value for two special client ids.
const realWrite = http.ServerResponse.prototype.write;
http.ServerResponse.prototype.write = function (chunk, ...rest) {
  const ok = realWrite.call(this, chunk, ...rest);
  const url = (this.req && this.req.url) || '';
  if (url.includes('clientId=stuck')) return false; // never drains
  if (url.includes('clientId=hiccup')) {
    this.__n = (this.__n || 0) + 1;
    if (this.__n === 4) { setImmediate(() => this.emit('drain')); return false; } // drains right away
  }
  return ok;
};

http.createServer((req, res) => {
  res.setHeader('Content-Type', 'application/json');
  if (req.url === '/gc' && global.gc) { global.gc(); }
  res.end(JSON.stringify({ liveIntervals: live.size, heapUsed: process.memoryUsage().heapUsed }));
}).listen(Number(process.env.PROBE_PORT), '127.0.0.1');
EOF

# ---- node helpers ----------------------------------------------------------------------
cat >"$TMP/h.js" <<'EOF'
'use strict';
const http = require('http');
const [mode, base, ...args] = process.argv.slice(2);
const u = new URL(base);

// Open /stream, resolve with { status, body (first chunk), req }.
function open(query) {
  return new Promise((resolve) => {
    const req = http.get({ host: u.hostname, port: u.port, path: '/stream' + query, agent: false }, (res) => {
      if (res.statusCode !== 200) {
        let b = '';
        res.on('data', (c) => (b += c)).on('end', () => resolve({ status: res.statusCode, body: b, req, res }));
        return;
      }
      res.once('data', (c) => resolve({ status: 200, body: String(c), req, res }));
    });
    req.on('error', () => resolve({ status: 0, body: '', req }));
  });
}

async function sanitize() {
  const cases = [
    ['dev-1', 'dev-1'],
    ['  padded  ', 'padded'],
    ['', 'anonymous'],
    ['!!!@@@', 'anonymous'],
    ['a'.repeat(50), 'a'.repeat(30)],
    ['<img src=x onerror=alert(1)>', 'img srcx onerroralert1'],
    ['\u65e5\u672c\u8a9e', 'anonymous'],
    ['x\r\nevent: log', 'xevent log'],
  ];
  let bad = 0;
  for (const [input, want] of cases) {
    const r = await open('?clientId=' + encodeURIComponent(input));
    const m = /"clientId":"([^"]*)"/.exec(r.body);
    const got = m ? m[1] : '(none)';
    if (got !== want) { bad++; console.log('MISMATCH ' + JSON.stringify(input) + ' -> ' + JSON.stringify(got) + ', want ' + JSON.stringify(want)); }
    r.req.destroy();
  }
  // missing param, and repeated param (Express parses it as an array)
  for (const q of ['', '?clientId=a&clientId=b', '?clientId[]=a']) {
    const r = await open(q);
    const m = /"clientId":"([^"]*)"/.exec(r.body);
    if (!m || m[1] !== 'anonymous') { bad++; console.log('MISMATCH query ' + q + ' -> ' + (m ? m[1] : '(none)')); }
    r.req.destroy();
  }
  console.log(bad === 0 ? 'OK' : 'BAD ' + bad);
}

async function cap() {
  const max = Number(args[0]);
  const open100 = [];
  for (let i = 0; i < max; i++) open100.push(open('?clientId=cap' + i));
  const got = await Promise.all(open100);
  console.log('OPENED ' + got.filter((r) => r.status === 200).length);
  const extra = await open('?clientId=overflow');
  console.log('OVERFLOW ' + extra.status + ' ' + extra.body.replace(/\s+/g, ''));
  console.log('RETRYAFTER ' + (extra.res && extra.res.headers['retry-after']));
  // free exactly one slot, the next stream must be accepted
  got[0].req.destroy();
  await new Promise((r) => setTimeout(r, 400));
  const again = await open('?clientId=after-free');
  console.log('AFTERFREE ' + again.status);
  again.req.destroy();
  console.log('READY');
  // keep the connections open until the parent closes stdin
  process.stdin.resume();
  process.stdin.on('end', () => { got.forEach((r) => r.req.destroy()); setTimeout(() => process.exit(0), 100); });
}

// Many short-lived connections, some aborted before the first byte, some after.
async function storm() {
  const total = Number(args[0]);
  const conc = Number(args[1]);
  const clientId = args[2] || 'storm';
  let started = 0;
  let done = 0;
  const ids = new Set();
  let dup = 0;
  async function one() {
    const abortAfter = Math.random() < 0.4 ? 0 : Math.floor(Math.random() * 250);
    await new Promise((resolve) => {
      const req = http.get({ host: u.hostname, port: u.port, path: '/stream?clientId=' + clientId, agent: false }, (res) => {
        res.once('data', (c) => {
          const m = /"sessionId":"([^"]+)"/.exec(String(c));
          if (m) { if (ids.has(m[1])) dup++; ids.add(m[1]); }
        });
      });
      req.on('error', () => {});
      req.on('close', resolve);
      setTimeout(() => req.destroy(), abortAfter);
    });
    done++;
  }
  async function worker() { while (started < total) { started++; await one(); } }
  await Promise.all(Array.from({ length: conc }, worker));
  console.log('DONE ' + done + ' DUPLICATE_SESSION_IDS ' + dup);
}

({ sanitize, cap, storm })[mode]().catch((e) => { console.log('ERR ' + e.message); process.exit(1); });
EOF

# ---- boot ------------------------------------------------------------------------------
section "0. Boot"
for tool in curl node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool"; exit 2; }
done
PORT="$TEST_PORT" PROBE_PORT="$PROBE_PORT" node --expose-gc -r "$TMP/probe.js" "$ROOT/server.js" >"$TMP/server.out" 2>&1 &
SERVER_PID=$!
if ! wait_for active_is 0; then
  echo "server not reachable at $BASE"; cat "$TMP/server.out"; exit 2
fi
TIMERS_BASE=$(timers)
echo "  server pid $SERVER_PID on $BASE, baseline timers=$TIMERS_BASE"

# ============================================================================
section "1. clientId sanitization (server side)"
out=$(node "$TMP/h.js" sanitize "$BASE")
check "10 inputs (long, empty, symbols, HTML, unicode, CRLF, array) all sanitized" OK "$(printf '%s' "$out" | tail -1)"
[ "$(printf '%s' "$out" | tail -1)" = OK ] || printf '%s\n' "$out" | sed 's/^/        /'
wait_for active_is 0; check "all those sessions were released" 0 "$(active)"

# ============================================================================
section "2. MAX_SESSIONS cap (100) -> 503"
mkfifo "$TMP/cap.in" 2>/dev/null
node "$TMP/h.js" cap "$BASE" 100 <"$TMP/cap.in" >"$TMP/cap.out" 2>&1 &
CAP_PID=$!
EXTRA_PIDS+=("$CAP_PID")
exec 7>"$TMP/cap.in"   # keep the fifo open: closing fd 7 later tells the helper to disconnect
wait_for grep -q '^READY' "$TMP/cap.out"
check "100 streams accepted" "OPENED 100" "$(grep '^OPENED' "$TMP/cap.out")"
check "101st stream rejected with 503 + JSON error" 'OVERFLOW 503 {"error":"toomanyactivestreams(max100)"}' "$(grep '^OVERFLOW' "$TMP/cap.out")"
check "503 carries a Retry-After header" "RETRYAFTER 5" "$(grep '^RETRYAFTER' "$TMP/cap.out")"
check "after one slot was freed a new stream is accepted" "AFTERFREE 200" "$(grep '^AFTERFREE' "$TMP/cap.out")"
check "active = 99 (100 accepted, 1 freed, the replacement closed again)" 99 "$(active)"
check "live timers = base + 2 x sessions while at the cap" "$((TIMERS_BASE + 2 * 99))" "$(timers)"
exec 7>&-
wait_for active_is 0; check "all released after the clients left" 0 "$(active)"
wait_for timers_are "$TIMERS_BASE"; check "timers back to baseline" "$TIMERS_BASE" "$(timers)"

# ============================================================================
section "4. Backpressure: stop producing, drop a client that never drains"
curl -sN --max-time 20 "$BASE/stream?clientId=stuck" >"$TMP/stuck.out" 2>/dev/null &
EXTRA_PIDS+=("$!")
curl -sN --max-time 20 "$BASE/stream?clientId=hiccup" >"$TMP/hiccup.out" 2>/dev/null &
EXTRA_PIDS+=("$!")
wait_for active_is 2
sleep 3.2
check "after 3 s both sessions are still alive (stuck is only skipping ticks)" 2 "$(active)"
LOGS_STUCK=$(grep -c '^event: log$' "$TMP/stuck.out")
LOGS_HICCUP=$(grep -c '^event: log$' "$TMP/hiccup.out")
[ "$LOGS_STUCK" -le 5 ] && pass "stuck client got no new logs while blocked ($LOGS_STUCK frames)" || fail "stuck client kept receiving logs ($LOGS_STUCK frames)"
[ "$LOGS_HICCUP" -ge 5 ] && pass "hiccup client recovered after drain and kept streaming ($LOGS_HICCUP frames)" || fail "hiccup client did not recover ($LOGS_HICCUP frames)"
# 10 skipped ticks x 500 ms = 5 s after the block started
if wait_for active_is 1; then pass "stuck session dropped after 10 skipped ticks"; else fail "stuck session was NOT dropped"; fi
check "hiccup session survived" true "$(json_get "$DEBUG_URL" "d.sessions.length === 1 && d.sessions[0].clientId === 'hiccup'")"
grep -q 'client="stuck" closed (backpressure)' "$TMP/server.out" && pass "server log says closed (backpressure)" || fail "no backpressure close in server log"
pkill -f "clientId=hiccup" 2>/dev/null
wait_for active_is 0; wait_for timers_are "$TIMERS_BASE"
check "everything released, timers at baseline" "0 $TIMERS_BASE" "$(active) $(timers)"

# ============================================================================
section "5. Rapid reconnect storm"
out=$(node "$TMP/h.js" storm "$BASE" 400 40 storm)
check "400 connect/abort cycles, 40 at once, same clientId" "DONE 400 DUPLICATE_SESSION_IDS 0" "$out"
wait_for active_is 0; check "active back to 0" 0 "$(active)"
wait_for timers_are "$TIMERS_BASE"; check "no orphaned timers" "$TIMERS_BASE" "$(timers)"
check "server log: every open has exactly one close" "$(grep -c '\] + session ' "$TMP/server.out")" "$(grep -c '\] - session ' "$TMP/server.out")"
check "no session closed twice" 0 "$(grep '\] - session ' "$TMP/server.out" | grep -o 'session [0-9a-f]\{8\}' | sort | uniq -d | wc -l | tr -d ' ')"

# ============================================================================
section "6. Memory stays flat (heapUsed after forced GC)"
node "$TMP/h.js" storm "$BASE" 300 40 warmup >/dev/null
wait_for active_is 0
H1=$(curl -s "$PROBE_URL/gc" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>console.log(JSON.parse(s).heapUsed))')
if [ "${LONG:-0}" = 1 ]; then ROUNDS=12000; else ROUNDS=2500; fi
node "$TMP/h.js" storm "$BASE" "$ROUNDS" 40 soak >/dev/null
wait_for active_is 0
H2=$(curl -s "$PROBE_URL/gc" | node -e 'let s="";process.stdin.on("data",c=>s+=c).on("end",()=>console.log(JSON.parse(s).heapUsed))')
GROWTH=$(( (H2 - H1) / 1024 ))
echo "  heapUsed after warm-up: $((H1 / 1024)) KB, after $ROUNDS more sessions: $((H2 / 1024)) KB (growth ${GROWTH} KB)"
[ "$GROWTH" -lt 5120 ] && pass "heap growth under 5 MB after $ROUNDS sessions" || fail "heap grew by ${GROWTH} KB"
check "no timers left after the soak" "$TIMERS_BASE" "$(timers)"

# ============================================================================
section "7. XSS: <img src=x onerror=alert(1)> is only ever text"
XSS='<img src=x onerror=alert(1)>'
timeout 1 curl -sN -G "$BASE/stream" --data-urlencode "clientId=$XSS" >"$TMP/xss1.out" 2>/dev/null
check "as clientId: server strips < > = ( ) before echoing it" 0 "$(head -2 "$TMP/xss1.out" | grep -c '[<>=()]')"
timeout 2 curl -sN "$BASE/stream?clientId=xss" >"$TMP/xss2.out" 2>/dev/null &
EXTRA_PIDS+=("$!")
wait_for active_is 1
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inject" -H 'Content-Type: application/json' \
  -d "{\"message\":\"$XSS\",\"target\":\"xss\"}")
sleep 0.3
check "as injected message: accepted" 200 "$code"
check "arrives inside a JSON string of an 'injected' event (data, not markup)" 1 "$(grep -c '^data: {"level":"CUSTOM".*"message":"<img src=x onerror=alert(1)>"' "$TMP/xss2.out")"
UNSAFE=$(grep -nE 'innerHTML|outerHTML|insertAdjacentHTML|document\.write|eval\(' "$ROOT"/public/*.js "$ROOT"/public/*.html | wc -l | tr -d ' ')
check "frontend uses no innerHTML / outerHTML / insertAdjacentHTML / document.write / eval" 0 "$UNSAFE"
check "frontend renders log text with textContent" true "$(grep -q 'textContent = entry.text' "$ROOT/public/app.js" && echo true || echo false)"
wait_for active_is 0

# ============================================================================
section "8. Refresh / back-forward cache (static part; the browser part is manual)"
for ev in beforeunload pagehide pageshow; do
  check "app.js handles '$ev'" true "$(grep -q "addEventListener('$ev'" "$ROOT/public/app.js" && echo true || echo false)"
done
echo "  (a client that disappears is covered by checks 4 and 5; real bfcache needs a browser, see README)"

# ============================================================================
section "9. Unknown routes and bad input never crash the server"
check "GET /nope -> 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/nope")"
check "404 body is plain text, not a stack trace" "404 Not Found" "$(curl -s "$BASE/nope")"
check "GET /api/nope -> 404 JSON" '{"error":"not found"}' "$(curl -s "$BASE/api/nope")"
check "GET /api/inject (wrong method) -> 404" 404 "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/inject")"
check "broken percent-encoding in the URL -> a 4xx, no crash" true "$(c=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$BASE/%E0%A4%A"); [ "$c" -ge 400 ] && [ "$c" -lt 500 ] && echo true || echo false)"
check "POST malformed JSON -> 400" 400 "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/inject" -H 'Content-Type: application/json' -d '{bad')"
check "path traversal attempt -> 4xx, no crash" true "$(c=$(curl -s --path-as-is -o /dev/null -w '%{http_code}' "$BASE/../../etc/passwd"); [ "$c" -ge 400 ] && [ "$c" -lt 500 ] && echo true || echo false)"
kill -0 "$SERVER_PID" 2>/dev/null && pass "server process still alive" || fail "server process died"
check "no stack traces or uncaught errors in server output" 0 "$(grep -cE 'uncaught|unhandled|TypeError|ReferenceError|^[[:space:]]+at ' "$TMP/server.out")"

# ============================================================================
section "3. Graceful shutdown (SIGTERM and SIGINT, with 3 live streams each)"
for SIG in TERM INT; do
  PORT="$SHUT_PORT" PROBE_PORT=3399 node -r "$TMP/probe.js" "$ROOT/server.js" >"$TMP/shut-$SIG.out" 2>&1 &
  SPID=$!
  EXTRA_PIDS+=("$SPID")
  for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$SHUT_PORT/api/debug/sessions" && break; sleep 0.1; done
  CPIDS=()
  for n in 1 2 3; do
    curl -sN --max-time 20 "http://127.0.0.1:$SHUT_PORT/stream?clientId=s$n" >"$TMP/shut-$SIG-$n.out" 2>/dev/null &
    CPIDS+=("$!")
  done
  for _ in $(seq 1 50); do
    [ "$(curl -s "http://127.0.0.1:$SHUT_PORT/api/debug/sessions" | grep -o '"active":[0-9]*')" = '"active":3' ] && break
    sleep 0.1
  done
  T0=$(node -p 'Date.now()')
  kill "-$SIG" "$SPID"
  wait "$SPID" 2>/dev/null; SRV_RC=$?
  T1=$(node -p 'Date.now()')
  BAD_CURL=0
  for cp in "${CPIDS[@]}"; do wait "$cp" 2>/dev/null; [ $? -eq 0 ] || BAD_CURL=$((BAD_CURL + 1)); done
  check "SIG$SIG: server exited with code 0" 0 "$SRV_RC"
  [ $((T1 - T0)) -lt 3000 ] && pass "SIG$SIG: exited within 3 s ($((T1 - T0)) ms)" || fail "SIG$SIG: slow exit ($((T1 - T0)) ms)"
  check "SIG$SIG: all 3 streams were ended cleanly by the server (curl exit 0)" 0 "$BAD_CURL"
  grep -q 'ended 3 session(s)' "$TMP/shut-$SIG.out" && pass "SIG$SIG: log says ended 3 session(s)" || fail "SIG$SIG: missing 'ended 3 session(s)' log line"
  curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SHUT_PORT/" && fail "SIG$SIG: port still accepting connections" || pass "SIG$SIG: port closed"
done

printf '\nRESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { printf '\n--- last server output ---\n'; tail -n 15 "$TMP/server.out"; exit 1; }
exit 0
