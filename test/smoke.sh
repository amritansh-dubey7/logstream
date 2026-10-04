#!/usr/bin/env bash
# smoke.sh - Concurrency and leak smoke test for LogStream (Phase 6).
#
#   bash test/smoke.sh
#       Starts its own server on TEST_PORT (default 3100) with a tiny timer probe
#       preloaded, runs every check, then stops the server.
#
#   LOGSTREAM_URL=http://localhost:3000 bash test/smoke.sh
#       Tests a server you already started. Counts are asserted relative to the
#       server's current `active` value, so it still works if something else is
#       connected. The timer-level checks need the probe, so they are skipped.
#
# What it proves (curl + the public debug route; no server code is modified):
#   1. 3 concurrent streams with different IDs -> active +3, distinct sessionIds
#   2. streams are independent: own session event, own clientId, own log lines
#      (no log line shared between any two streams), ~500 ms cadence each
#   3. killing one stream drops active by exactly one within DETECT_LIMIT_MS and
#      the survivors keep streaming
#   4. killing the rest (SIGKILL and SIGTERM) -> active back to baseline
#   5. two streams sharing one clientId are still two sessions
#   6. a burst of short-lived / aborted connections leaves nothing behind
#   7. EventSource.close() (the Stop button's call) releases the session while the
#      client process is still alive, and no event arrives after it
#   8. (own-server mode) live setInterval handles == baseline + 2 x active at
#      every step, so a timer that outlived its session cannot hide behind a
#      correct `active` count; the server log shows every open closed exactly once,
#      always by a close/error event for established streams (never by the 500 ms
#      write-guard fallback, which would still pass a 1 s timing check)
#
# Needs: bash, curl, node (already required by the project). No jq.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_PORT="${TEST_PORT:-3100}"
PROBE_PORT="${PROBE_PORT:-3101}"
DETECT_LIMIT_MS="${DETECT_LIMIT_MS:-1000}"
LOG_INTERVAL_MS=500
STREAM_MAX_TIME=120   # safety net: orphaned curls die on their own even if this script is SIGKILLed

if [ -n "${LOGSTREAM_URL:-}" ]; then
  BASE="${LOGSTREAM_URL%/}"
  OWN_SERVER=0
else
  BASE="http://127.0.0.1:${TEST_PORT}"
  OWN_SERVER=1
fi
DEBUG_URL="$BASE/api/debug/sessions"
PROBE_URL="http://127.0.0.1:${PROBE_PORT}/"

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t logstream-smoke)"
SERVER_PID=""
CURL_PIDS=()
LAST_PID=""
LATENCY_MS=-1
LATENCIES=""
PASS=0
FAIL=0
SKIP=0
BASE_ACTIVE=0
TIMERS_BASE=0

cleanup() {
  local p
  for p in "${CURL_PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# ---- tiny assertion framework ------------------------------------------------
pass() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s\n' "$1"; }
section() { printf '\n== %s\n' "$1"; }
check() { # check <description> <expected> <actual>
  if [ "$2" = "$3" ]; then pass "$1 (= $3)"; else fail "$1 (expected $2, got $3)"; fi
}
assert() { # assert <description> <command...>
  local desc="$1"
  shift
  if "$@"; then pass "$desc"; else fail "$desc"; fi
}

# ---- node-backed helpers (no jq dependency) ------------------------------------
now_ms() { node -p 'Date.now()'; }

# jx <json-file> <js-expression over d>
jx() {
  node -e '
    const d = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
    console.log(new Function("d", "return (" + process.argv[2] + ")")(d));
  ' "$1" "$2"
}

# json_get <url> <js-expression over d>
json_get() {
  curl -s --max-time 3 "$1" | node -e '
    let s = "";
    process.stdin.on("data", (c) => (s += c)).on("end", () => {
      try { console.log(new Function("d", "return (" + process.argv[1] + ")")(JSON.parse(s))); }
      catch (e) { console.log("ERR"); }
    });
  ' "$2"
}

# wait_until <url> <js-expression over d> <expected-string> <timeout_ms>
# Polls every 25 ms. Prints the epoch-ms at which it became true (exit 0), or
# "TIMEOUT <last value>" (exit 1).
wait_until() {
  node -e '
    const http = require("http");
    const [url, expr, want, timeoutMs] = process.argv.slice(1);
    const get = new Function("d", "return (" + expr + ")");
    const deadline = Date.now() + Number(timeoutMs);
    let last = "n/a";
    (function poll() {
      const req = http.get(url, { timeout: 2000 }, (res) => {
        let s = "";
        res.on("data", (c) => (s += c));
        res.on("end", () => {
          try { last = String(get(JSON.parse(s))); } catch (e) { last = "ERR"; }
          if (last === want) { console.log(Date.now()); process.exit(0); }
          if (Date.now() > deadline) { console.log("TIMEOUT " + last); process.exit(1); }
          setTimeout(poll, 25);
        });
      });
      req.on("error", () => {
        if (Date.now() > deadline) { console.log("TIMEOUT unreachable"); process.exit(1); }
        setTimeout(poll, 50);
      });
    })();
  ' "$1" "$2" "$3" "$4"
}

await_active() { # await_active <delta-from-baseline> [timeout_ms]
  wait_until "$DEBUG_URL" 'd.active' "$((BASE_ACTIVE + $1))" "${2:-5000}"
}

# ---- curl stream helpers --------------------------------------------------------
start_stream() { # start_stream <label> <clientId>   (sets LAST_PID)
  now_ms >"$TMP/$1.t0"
  curl -sN --max-time "$STREAM_MAX_TIME" "$BASE/stream?clientId=$2" >"$TMP/$1.out" 2>"$TMP/$1.err" &
  LAST_PID=$!
  CURL_PIDS+=("$LAST_PID")
  disown "$LAST_PID" 2>/dev/null   # no "Killed" job notices when we kill -9 it later
}

# Block until the (disowned) process is really gone, so nothing lingers into the next check.
reap() {
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.02; i=$((i + 1)); done
}

# measure_release <pid> <signal> <expected absolute active after release>
# Sets LATENCY_MS (client-side kill -> server's active count reaches the target).
# Includes ~2 node start-ups, so it slightly overestimates (about +-50 ms).
measure_release() {
  local t0 out
  t0=$(now_ms)
  kill "-$2" "$1" 2>/dev/null
  if out=$(wait_until "$DEBUG_URL" 'd.active' "$3" 5000); then
    LATENCY_MS=$((out - t0))
  else
    LATENCY_MS=-1
  fi
  reap "$1"
}

record_latency() { # record_latency <label>
  LATENCIES="${LATENCIES}  $1: ${LATENCY_MS} ms\n"
  if [ "$LATENCY_MS" -ge 0 ] && [ "$LATENCY_MS" -le "$DETECT_LIMIT_MS" ]; then
    pass "$1: server released the session within ${DETECT_LIMIT_MS} ms (${LATENCY_MS} ms)"
  else
    fail "$1: server did NOT release the session within ${DETECT_LIMIT_MS} ms (${LATENCY_MS} ms)"
  fi
}

count_logs() { grep -c '^event: log$' "$TMP/$1.out"; }
sse_field() { sed -n "s/^data: .*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1" | head -1; }

# ---- timer probe (own-server mode only) ---------------------------------------
# Preloaded with `node -r`. Counts live setInterval handles created through the
# global setInterval (i.e. by server.js) and serves the number on PROBE_PORT.
write_probe() {
  cat >"$TMP/probe.js" <<'EOF'
'use strict';
const http = require('http');
const live = new Set();
const origSet = global.setInterval;
const origClearInterval = global.clearInterval;
const origClearTimeout = global.clearTimeout;
global.setInterval = function (...args) {
  const t = origSet.apply(this, args);
  live.add(t);
  return t;
};
global.clearInterval = function (t) { live.delete(t); return origClearInterval.call(this, t); };
global.clearTimeout = function (t) { live.delete(t); return origClearTimeout.call(this, t); };
http
  .createServer((_req, res) => {
    res.setHeader('Content-Type', 'application/json');
    res.setHeader('Cache-Control', 'no-store');
    res.end(JSON.stringify({ liveIntervals: live.size }));
  })
  .listen(Number(process.env.PROBE_PORT), '127.0.0.1');
EOF
}

probe_intervals() { json_get "$PROBE_URL" 'd.liveIntervals'; }

# check_timers <description> <expected number of live sessions>
check_timers() {
  [ "$OWN_SERVER" = 1 ] || return 0
  check "$1 [live timers = base + 2 x sessions]" "$((TIMERS_BASE + 2 * $2))" "$(probe_intervals)"
}

# ============================================================================
# BOOT
# ============================================================================
section "0. Boot"
for tool in curl node; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing required tool: $tool"; exit 2; }
done

if [ "$OWN_SERVER" = 1 ]; then
  write_probe
  PORT="$TEST_PORT" PROBE_PORT="$PROBE_PORT" node -r "$TMP/probe.js" "$ROOT/server.js" >"$TMP/server.out" 2>&1 &
  SERVER_PID=$!
fi

if ! out=$(wait_until "$DEBUG_URL" 'typeof d.active' number 8000); then
  echo "server not reachable at $BASE ($out)"
  [ -f "$TMP/server.out" ] && cat "$TMP/server.out"
  exit 2
fi
if [ "$OWN_SERVER" = 1 ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "our server process died on startup (is port $TEST_PORT already in use?)"
  cat "$TMP/server.out"
  exit 2
fi

BASE_ACTIVE=$(json_get "$DEBUG_URL" 'd.active')
if [ "$OWN_SERVER" = 1 ]; then
  TIMERS_BASE=$(probe_intervals)
  echo "  own server on $BASE (pid $SERVER_PID), baseline active=$BASE_ACTIVE, baseline timers=$TIMERS_BASE"
  check "fresh server starts with 0 sessions" 0 "$BASE_ACTIVE"
else
  echo "  external server at $BASE, baseline active=$BASE_ACTIVE"
  skip "timer-level leak checks (need own-server mode to preload the probe)"
fi

# ============================================================================
# 1. THREE CONCURRENT STREAMS, DIFFERENT IDS
# ============================================================================
section "1. Three concurrent streams with different IDs"
start_stream alpha alpha;     PID_A=$LAST_PID
sleep 0.15
start_stream bravo bravo;     PID_B=$LAST_PID
sleep 0.15
start_stream charlie charlie; PID_C=$LAST_PID

await_active 3 3000 >/dev/null
check "active after starting 3 streams" "$((BASE_ACTIVE + 3))" "$(json_get "$DEBUG_URL" 'd.active')"
check_timers "3 streams open" 3

sleep 2.2
curl -s --max-time 3 "$DEBUG_URL" >"$TMP/debug1.json"

SID_A=$(sse_field "$TMP/alpha.out" sessionId)
SID_B=$(sse_field "$TMP/bravo.out" sessionId)
SID_C=$(sse_field "$TMP/charlie.out" sessionId)

check_stream() { # check_stream <label> <expected clientId> <sessionId>
  local label="$1" client="$2" sid="$3" n t0 now expected snap="$TMP/$1.snap"
  # One snapshot per stream: the live file keeps growing every 500 ms, and two separate
  # reads of it can straddle a tick and disagree by one frame.
  cp "$TMP/$label.out" "$snap"
  check "$label: first frame is the session event" "event: session" "$(head -n1 "$snap")"
  check "$label: session event carries its own clientId" "$client" "$(sse_field "$snap" clientId)"
  assert "$label: sessionId is a UUID v4" bash -c "printf '%s' '$sid' | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\$'"
  check "$label: debug route lists this sessionId with this clientId" true \
    "$(jx "$TMP/debug1.json" "d.sessions.some(s => s.sessionId === '$sid' && s.clientId === '$client')")"

  n=$(grep -c '^event: log$' "$snap")
  check "$label: every log frame is well-formed JSON with a [LEVEL] HH:MM:SS.mmm line" "$n" \
    "$(grep -cE '^data: \{"level":"(INFO|WARN|ERROR)",.*"line":"\[(INFO|WARN|ERROR)\] [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3} - .+"\}$' "$snap")"

  t0=$(cat "$TMP/$label.t0")
  now=$(now_ms)
  expected=$((1 + (now - t0) / LOG_INTERVAL_MS))
  if [ "$n" -ge $((expected - 2)) ] && [ "$n" -le $((expected + 2)) ]; then
    pass "$label: ~500 ms cadence ($n log frames, expected about $expected)"
  else
    fail "$label: cadence off ($n log frames, expected about $expected +-2)"
  fi
}
check_stream alpha alpha "$SID_A"
check_stream bravo bravo "$SID_B"
check_stream charlie charlie "$SID_C"

check "the 3 sessionIds are all distinct" 3 "$(printf '%s\n' "$SID_A" "$SID_B" "$SID_C" | sort -u | grep -c .)"
check "debug sessions are all distinct" true "$(jx "$TMP/debug1.json" 'new Set(d.sessions.map(s => s.sessionId)).size === d.sessions.length')"
check "debug route exposes only sessionId/clientId/startedAt (no res, no timers)" true \
  "$(jx "$TMP/debug1.json" 'd.sessions.every(s => Object.keys(s).sort().join() === "clientId,sessionId,startedAt")')"
check "debug route reports numeric memory" true \
  "$(jx "$TMP/debug1.json" 'typeof d.memory.rss === "number" && typeof d.memory.heapUsed === "number"')"

shared_lines() {
  local lbl total=0 n a b
  for lbl in alpha bravo charlie; do
    grep '^data: .*"line":' "$TMP/$lbl.out" | LC_ALL=C sort >"$TMP/$lbl.logs"
  done
  for pair in "alpha bravo" "alpha charlie" "bravo charlie"; do
    set -- $pair
    a=$1; b=$2
    n=$(LC_ALL=C comm -12 "$TMP/$a.logs" "$TMP/$b.logs" | wc -l | tr -d ' ')
    total=$((total + n))
  done
  echo "$total"
}
check "no log line is shared between any two streams (no bleed)" 0 "$(shared_lines)"

# ============================================================================
# 2. KILL ONE
# ============================================================================
section "2. Kill one stream (SIGTERM), the others must be unaffected"
A0=$(count_logs alpha)
C0=$(count_logs charlie)
measure_release "$PID_B" TERM "$((BASE_ACTIVE + 2))"
record_latency "SIGTERM on bravo"
check "active after killing 1 of 3" "$((BASE_ACTIVE + 2))" "$(json_get "$DEBUG_URL" 'd.active')"
check_timers "bravo killed" 2
curl -s --max-time 3 "$DEBUG_URL" >"$TMP/debug2.json"
check "bravo's session is gone from the debug route" false "$(jx "$TMP/debug2.json" "d.sessions.some(s => s.sessionId === '$SID_B')")"
check "alpha's session is still listed" true "$(jx "$TMP/debug2.json" "d.sessions.some(s => s.sessionId === '$SID_A')")"
check "charlie's session is still listed" true "$(jx "$TMP/debug2.json" "d.sessions.some(s => s.sessionId === '$SID_C')")"
sleep 1.2
assert "alpha kept streaming after bravo died ($A0 -> $(count_logs alpha))" [ "$(count_logs alpha)" -gt "$A0" ]
assert "charlie kept streaming after bravo died ($C0 -> $(count_logs charlie))" [ "$(count_logs charlie)" -gt "$C0" ]
check "active is still baseline + 2 (no collateral closes)" "$((BASE_ACTIVE + 2))" "$(json_get "$DEBUG_URL" 'd.active')"

# ============================================================================
# 3. KILL THE REST
# ============================================================================
section "3. Kill the rest (SIGKILL simulates a crashed tab, SIGTERM a closed one)"
measure_release "$PID_A" KILL "$((BASE_ACTIVE + 1))"
record_latency "SIGKILL on alpha"
check_timers "alpha killed" 1
measure_release "$PID_C" TERM "$BASE_ACTIVE"
record_latency "SIGTERM on charlie"
check "active back to baseline" "$BASE_ACTIVE" "$(json_get "$DEBUG_URL" 'd.active')"
check_timers "all streams closed" 0

# ============================================================================
# 4. TWO STREAMS, SAME CLIENT ID
# ============================================================================
section "4. Two streams sharing one clientId stay independent"
start_stream twin1 twin; PID_T1=$LAST_PID
start_stream twin2 twin; PID_T2=$LAST_PID
await_active 2 3000 >/dev/null
check "active with two same-name streams" "$((BASE_ACTIVE + 2))" "$(json_get "$DEBUG_URL" 'd.active')"
sleep 1.2
SID_T1=$(sse_field "$TMP/twin1.out" sessionId)
SID_T2=$(sse_field "$TMP/twin2.out" sessionId)
check "same clientId, different sessionIds" true \
  "$([ -n "$SID_T1" ] && [ -n "$SID_T2" ] && [ "$SID_T1" != "$SID_T2" ] && echo true || echo false)"
check "both report clientId 'twin'" "twin twin" "$(sse_field "$TMP/twin1.out" clientId) $(sse_field "$TMP/twin2.out" clientId)"
T2_0=$(count_logs twin2)
measure_release "$PID_T1" TERM "$((BASE_ACTIVE + 1))"
record_latency "SIGTERM on twin1"
curl -s --max-time 3 "$DEBUG_URL" >"$TMP/debug3.json"
check "only twin1's session was removed" "false true" \
  "$(jx "$TMP/debug3.json" "d.sessions.some(s => s.sessionId === '$SID_T1')") $(jx "$TMP/debug3.json" "d.sessions.some(s => s.sessionId === '$SID_T2')")"
sleep 1.2
assert "twin2 kept streaming ($T2_0 -> $(count_logs twin2))" [ "$(count_logs twin2)" -gt "$T2_0" ]
measure_release "$PID_T2" TERM "$BASE_ACTIVE"
record_latency "SIGTERM on twin2"
check_timers "twins closed" 0

# ============================================================================
# 5. CONNECTION CHURN
# ============================================================================
section "5. Churn: 35 connections aborted at random moments"
CHURN_PIDS=()
for i in $(seq 1 15); do   # abort ~immediately, around the first write
  curl -sN -m 0.08 "$BASE/stream?clientId=churn-fast-$i" >/dev/null 2>&1 &
  CHURN_PIDS+=("$!")
done
for i in $(seq 1 20); do   # abort after ~1.2 s, mid-stream
  curl -sN -m 1.2 "$BASE/stream?clientId=churn-slow-$i" >/dev/null 2>&1 &
  CHURN_PIDS+=("$!")
done
if wait_until "$DEBUG_URL" "d.active >= $((BASE_ACTIVE + 10))" true 2000 >/dev/null; then
  pass "burst really connected (active reached baseline + 10 or more)"
else
  fail "burst never reached baseline + 10 (test would be vacuous)"
fi
{ wait "${CHURN_PIDS[@]}"; } 2>/dev/null
if out=$(await_active 0 4000); then
  pass "active returned to baseline after the burst"
else
  fail "active did NOT return to baseline after the burst ($out)"
fi
check "active after burst" "$BASE_ACTIVE" "$(json_get "$DEBUG_URL" 'd.active')"
check_timers "after churn" 0

# ============================================================================
# 6. EventSource.close()  (exactly what the Stop button calls)
# ============================================================================
section "6. EventSource.close() releases the session (Stop button path)"
if node --experimental-eventsource -e 'process.exit(typeof EventSource === "function" ? 0 : 1)' 2>/dev/null; then
  # Node's experimental EventSource (not a browser, but the same spec'd client API app.js uses).
  # The client process deliberately stays alive for 1.5 s AFTER close(), so a session that
  # disappears can only be explained by close() itself, not by the process exiting.
  node --experimental-eventsource -e '
    const es = new EventSource(process.argv[1] + "/stream?clientId=es-close-test");
    let logs = 0, after = 0, closed = false;
    es.addEventListener("log", () => {
      if (closed) { after++; return; }
      if (++logs === 3) {
        es.close(); closed = true;
        console.log("CLOSED " + Date.now());
        setTimeout(() => { console.log("AFTER " + after); process.exit(0); }, 1500);
      }
    });
  ' "$BASE" >"$TMP/es.out" 2>/dev/null &
  ES_PID=$!
  CURL_PIDS+=("$ES_PID")
  disown "$ES_PID" 2>/dev/null
  ES_T=""
  for _ in $(seq 1 80); do   # up to ~4 s for 3 log events
    ES_T=$(sed -n 's/^CLOSED //p' "$TMP/es.out" 2>/dev/null | head -1)
    [ -n "$ES_T" ] && break
    sleep 0.05
  done
  if [ -z "$ES_T" ]; then
    fail "EventSource client never reached 3 log events"
  else
    if out=$(await_active 0 3000); then
      LATENCY_MS=$((out - ES_T))
      record_latency "EventSource.close()"
    else
      fail "session NOT released after EventSource.close() ($out)"
    fi
    assert "client process was still alive when the session was released" kill -0 "$ES_PID"
    reap "$ES_PID"
    check "no log events delivered to the client after close()" "AFTER 0" "$(grep '^AFTER ' "$TMP/es.out")"
    check_timers "after EventSource.close()" 0
  fi
else
  skip "EventSource.close() check (this Node has no --experimental-eventsource)"
fi

# ============================================================================
# 7. SERVER HEALTH
# ============================================================================
section "7. Server health"
check "debug route still answers 200" 200 "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$DEBUG_URL")"
if [ "$OWN_SERVER" = 1 ]; then
  assert "server process is still alive (no crash)" kill -0 "$SERVER_PID"
  check "no stack traces / unhandled errors in server output" 0 \
    "$(grep -cE 'Unhandled|TypeError|ReferenceError|ERR_[A-Z_]+|^[[:space:]]+at ' "$TMP/server.out")"
  OPENED=$(grep -c '\] + session ' "$TMP/server.out")
  CLOSED=$(grep -c '\] - session ' "$TMP/server.out")
  check "every opened session was closed (server log: opens == closes)" "$OPENED" "$CLOSED"
  # Established streams must be released by the close/error events. The only legitimate
  # write-guard closes are the "instant abort" churn clients that vanish before the first write.
  check "every established stream was released by a close/error event, not the write-guard fallback" 0 \
    "$(grep 'closed (write ' "$TMP/server.out" | grep -vc 'client="churn-fast-')"
  echo "  (info: $(grep 'closed (write ' "$TMP/server.out" | grep -c 'client="churn-fast-') of 15 instant-abort connections were closed by the write guard: client already gone before the first write)"
  check "no session was closed twice (idempotent cleanup)" 0 \
    "$(grep '\] - session ' "$TMP/server.out" | grep -o 'session [0-9a-f]\{8\}' | sort | uniq -d | wc -l | tr -d ' ')"
  echo "  (server handled $OPENED sessions in this run)"
fi

# ============================================================================
# SUMMARY
# ============================================================================
printf '\nDetection latency, client kill -> server active count updated:\n'
printf '%b' "$LATENCIES"
printf '\nRESULT: %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if [ "$FAIL" -gt 0 ]; then
  if [ -f "$TMP/server.out" ]; then
    printf '\n--- last server output ---\n'
    tail -n 20 "$TMP/server.out"
  fi
  exit 1
fi
exit 0
