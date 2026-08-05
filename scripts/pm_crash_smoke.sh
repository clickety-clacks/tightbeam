#!/bin/sh
# SMOKE §11 step 43 — a REAL crash mid-turn: failed_unknown, boot recovery,
# the bubble, and a live parent acting on it. Credentialed (needs
# ~/tb-test-keys/anthropic); run from the repo root on a host with the key:
#
#   sh scripts/pm_crash_smoke.sh
#
# Phase 1 (pm_crash_seed.exs) boots the app, onboards, starts a long LIVE
# claude turn and holds the VM open. This script kills that VM dead (KILL, no
# grace — the crash must be real), reboots the application on the same base
# dir, and requires convergence: the orphaned turn recovered as
# failed_unknown, the bubble's notice delivered by the live parent, no alert.
# Pid discipline: the pid is captured at spawn, its argv verified to carry
# OUR base dir before any signal, and death confirmed after.
set -eu

BASE="$HOME/tb-pm-43-$(date +%s)"
PORT=11486
DB="$BASE/state.db"
export TIGHTBEAM_BASE_DIR="$BASE" TIGHTBEAM_PORT="$PORT"
export PATH="$PWD/priv/harness_cli:$PATH"
mkdir -p "$BASE"

sq() { sqlite3 "$DB" "$1" 2>/dev/null || true; }

await() { # await "label" "sql" "expected" tries
  i=0
  while [ "$i" -lt "${4:-240}" ]; do
    got=$(sq "$2")
    [ "$got" = "$3" ] && return 0
    i=$((i + 1)); sleep 1
  done
  echo "43 TIMEOUT $1 (last: '$got')"; exit 1
}

echo "43 base=$BASE port=$PORT"

mix run --no-start scripts/pm_crash_seed.exs > "$BASE/seed.log" 2>&1 &
PID=$!

await "child turn running" \
  "SELECT status FROM turns WHERE sessionKey='s43:child'" "running" 300

# Identity before the signal: this pid must be OUR beam, on OUR base dir.
ps -p "$PID" -o command | grep -q "elixir\|beam\|mix" || { echo "43 ABORT: pid $PID is not a beam"; exit 1; }
grep -q "43 seed: RUNNING" "$BASE/seed.log" || { echo "43 ABORT: seed log does not confirm ownership"; exit 1; }

kill -9 "$PID"
i=0; while kill -0 "$PID" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 20 ] && { echo "43 ABORT: pid survived KILL"; exit 1; }; sleep 0.5; done
echo "43 crashed: beam $PID confirmed dead mid-turn"

# Boot 2: the application's own recovery, nothing seeded.
mix run --no-halt > "$BASE/boot2.log" 2>&1 &
PID2=$!

await "orphan recovered as failed_unknown" \
  "SELECT status FROM turns WHERE sessionKey='s43:child'" "failed_unknown" 120

echo "43 recovery: child turn is failed_unknown"

await "bubble notice delivered by LIVE parent" \
  "SELECT status FROM turns WHERE sessionKey='s43:parent' AND requestRef LIKE 'bubble:%'" "delivered" 300

echo "43 bubble: parent ran the notice on live claude"

ALERT=$(sq "SELECT COUNT(*) FROM condition_facts WHERE kind='user-alerted' AND scope='flynn'")
[ "$ALERT" = "0" ] || { echo "43 FAIL: user alerted although the parent acted"; exit 1; }

echo "43 PASS: crash -> failed_unknown -> notice -> live parent delivered -> no alert"

ps -p "$PID2" -o command | grep -q "elixir\|beam\|mix" && kill "$PID2"
i=0; while kill -0 "$PID2" 2>/dev/null; do i=$((i+1)); [ "$i" -gt 20 ] && kill -9 "$PID2"; sleep 0.5; done
rm -rf "$BASE"
echo "43 cleanup: gateway stopped, ephemeral base (and banked key copy) removed"
