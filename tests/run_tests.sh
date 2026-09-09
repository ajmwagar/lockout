#!/usr/bin/env bash
#
# lockout test suite. No framework: plain bash, exits non-zero on failure.
# Every test runs against a throwaway LOCKOUT_HOME so it never touches the
# caller's real queue.

set -uo pipefail

HERE=$(cd -P "$(dirname "$0")" && pwd)
# LOCKOUT_BIN lets CI point the suite at a copy with a different shebang, so
# the same tests can be run against stock bash 3.2 and against bash 5.
LOCKOUT=${LOCKOUT_BIN:-$HERE/../bin/lockout}
[ -x "$LOCKOUT" ] || { echo "cannot find executable $LOCKOUT" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/lockout-test.XXXXXX") || exit 1
export LOCKOUT_HOME=$TMP/state
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0

start() { printf '  %-46s' "$1"; }
ok()    { PASS=$((PASS + 1)); printf 'ok\n'; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL\n'; printf '      %s\n' "$*" >&2; }
check() { if [ "$1" = "$2" ]; then ok; else bad "expected '$2', got '$1'"; fi; }

# Fresh scope per test so ids and limits never leak between them.
scope() { export LOCKOUT_SCOPE=$1; unset LOCKOUT_LIMIT; }

# Highest number of jobs seen running at once, derived from a trace file that
# each job appends '+' to on entry and '-' to on exit. Single-byte O_APPEND
# writes are atomic, so the trace is a faithful interleaving.
max_concurrency() {
  awk 'BEGIN{RS="";} {
    n=split($0, _, ""); cur=0; max=0;
    for (i=1;i<=length($0);i++) {
      c=substr($0,i,1);
      if (c=="+") { cur++; if (cur>max) max=cur }
      else if (c=="-") cur--
    }
    print max
  }' "$1"
}

echo "lockout tests  (state: $LOCKOUT_HOME)"

# --------------------------------------------------------------- basics ----

scope basics
start "runs a command and propagates exit 0"
out=$("$LOCKOUT" run -- echo hi 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = hi ] && ok || bad "rc=$rc out='$out'"

start "propagates a non-zero exit code"
"$LOCKOUT" run -- sh -c 'exit 7' >/dev/null 2>&1
check "$?" 7

start "passes arguments through untouched"
out=$("$LOCKOUT" run -- printf '%s|' a 'b c' '$d' 2>/dev/null)
check "$out" 'a|b c|$d|'

start "runs in the caller's working directory"
out=$(cd "$TMP" && "$LOCKOUT" run -- pwd 2>/dev/null)
check "$(cd "$TMP" && pwd)" "$out"

start "rejects an empty command"
"$LOCKOUT" run -- >/dev/null 2>&1
check "$?" 1

# ---------------------------------------------------------- exclusion ------

scope excl1
start "limit 1 serialises concurrent jobs"
trace=$TMP/trace1; : > "$trace"
for i in 1 2 3 4; do
  "$LOCKOUT" run -q -- sh -c "printf '+' >> '$trace'; sleep 0.4; printf -- '-' >> '$trace'" &
done
wait
check "$(max_concurrency "$trace")" 1

scope excl3
start "limit 3 admits exactly three at a time"
"$LOCKOUT" limit 3 >/dev/null
trace=$TMP/trace3; : > "$trace"
for i in 1 2 3 4 5 6; do
  "$LOCKOUT" run -q -- sh -c "printf '+' >> '$trace'; sleep 0.6; printf -- '-' >> '$trace'" &
done
wait
check "$(max_concurrency "$trace")" 3

scope isolation
start "separate scopes do not block each other"
other=$TMP/trace-iso; : > "$other"
LOCKOUT_SCOPE=iso_a "$LOCKOUT" run -q -- sh -c "printf '+' >> '$other'; sleep 0.5; printf -- '-' >> '$other'" &
LOCKOUT_SCOPE=iso_b "$LOCKOUT" run -q -- sh -c "printf '+' >> '$other'; sleep 0.5; printf -- '-' >> '$other'" &
wait
check "$(max_concurrency "$other")" 2

# --------------------------------------------------------------- fifo ------

scope fifo
start "admits jobs first-come-first-served"
order=$TMP/order; : > "$order"
ids=""
for i in 1 2 3 4; do
  # submit enqueues synchronously, so ticket order is deterministic here.
  id=$("$LOCKOUT" submit -q -- sh -c "echo $i >> '$order'; sleep 0.2")
  ids="$ids $id"
done
"$LOCKOUT" wait $ids >/dev/null 2>&1
check "$(tr '\n' ' ' < "$order")" "1 2 3 4 "

# ------------------------------------------------------------- recovery ----

scope reaping
start "frees the slot when a holder is killed"
"$LOCKOUT" run -q -- sleep 33.7 >/dev/null 2>&1 &
holder=$!
sleep 0.6
kill -9 "$holder" 2>/dev/null
# The orphaned child keeps running; the point is that its slot is reclaimed.
t0=$SECONDS
"$LOCKOUT" run -q -- true >/dev/null 2>&1
took=$((SECONDS - t0))
pkill -f 'sleep 33.7' 2>/dev/null
[ "$took" -le 5 ] && ok || bad "waited ${took}s for a slot that should have been reaped"

start "marks an abandoned job in status"
out=$("$LOCKOUT" status --all 2>/dev/null | grep -c 'abandoned')
[ "$out" -ge 1 ] && ok || bad "no abandoned note in status"

scope stalelock
start "reclaims a control lock left by a dead process"
mkdir -p "$LOCKOUT_HOME/stalelock/jobs"
mkdir -p "$LOCKOUT_HOME/stalelock/ctl.lock"
# 2^30 is a pid that cannot be live on any sane system.
printf '1073741824 %s\n' "$(date +%s)" > "$LOCKOUT_HOME/stalelock/ctl.lock/owner"
t0=$SECONDS
"$LOCKOUT" run -q -- true >/dev/null 2>&1; rc=$?
took=$((SECONDS - t0))
[ "$rc" = 0 ] && [ "$took" -le 5 ] && ok || bad "rc=$rc took=${took}s"

# ------------------------------------------------------------ re-entrancy --

scope nested
start "nested lockout call does not deadlock"
out=$("$LOCKOUT" run -q -- "$LOCKOUT" run -q -- echo inner 2>/dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = inner ] && ok || bad "rc=$rc out='$out'"

start "nested call in another scope still queues"
out=$("$LOCKOUT" run -q -- env LOCKOUT_SCOPE=nested_other "$LOCKOUT" run -q -- echo deep 2>/dev/null)
check "$out" deep

# ------------------------------------------------------- submit / monitor --

scope submitting
start "submit returns immediately with a job id"
t0=$SECONDS
id=$("$LOCKOUT" submit -q -- sh -c 'echo streamed; sleep 0.3')
took=$((SECONDS - t0))
[ -n "$id" ] && [ "$took" -le 2 ] && ok || bad "id='$id' took=${took}s"

start "wait blocks until the job is done"
"$LOCKOUT" wait "$id" >/dev/null 2>&1
check "$("$LOCKOUT" status --all | grep -c "^$id  *done")" 1

start "logs capture a submitted job's output"
check "$("$LOCKOUT" logs "$id")" streamed

start "wait returns the job's exit code"
id=$("$LOCKOUT" submit -q -- sh -c 'exit 9')
"$LOCKOUT" wait "$id" >/dev/null 2>&1
check "$?" 9

start "wait with no arguments drains the queue"
for i in 1 2 3; do "$LOCKOUT" submit -q -- sleep 0.2 >/dev/null; done
"$LOCKOUT" wait >/dev/null 2>&1
ctl=$("$LOCKOUT" status --json | sed 's/.*"running":\([0-9]*\),"queued":\([0-9]*\).*/\1 \2/')
check "$ctl" "0 0"

# ------------------------------------------------------------- status ------

scope statusing
start "status shows a queued job behind a running one"
"$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
"$LOCKOUT" submit -q -- sleep 0.2 >/dev/null
sleep 0.6
js=$("$LOCKOUT" status --json)
r=$(printf '%s' "$js" | sed 's/.*"running":\([0-9]*\).*/\1/')
q=$(printf '%s' "$js" | sed 's/.*"queued":\([0-9]*\).*/\1/')
check "$r $q" "1 1"

start "recorded command round-trips through the shell"
"$LOCKOUT" wait >/dev/null 2>&1
"$LOCKOUT" run -q -- printf '%s|' 'a b' "it's" '"dq"' '$notavar' >/dev/null 2>&1
# The whole point of recording the command is that a human can paste it back.
recorded=$("$LOCKOUT" status --all | tail -1 | sed 's/^ *[0-9]*  *[a-z:0-9?]*  *[0-9:]*  *[0-9:-]*  *[0-9-]*  *//')
check "$(eval "$recorded")" 'a b|it'"'"'s|"dq"|$notavar|' 

# No JSON parser is assumed to exist, so check structurally: every key must
# carry a value. A missing one shows up as ":," or ":}" and is exactly the
# shape of the empty-jobs bug this catches.
json_well_formed() {
  case $1 in
    '{'*'}') ;;
    *) return 1 ;;
  esac
  case $1 in
    *':,'*|*':}'*|*':]'*|*'[,'*) return 1 ;;
  esac
  return 0
}

start "json is well formed with jobs present"
js=$("$LOCKOUT" status --all --json)
json_well_formed "$js" && ok || bad "malformed: $js"

start "json is well formed with no jobs at all"
LOCKOUT_SCOPE=empty_scope "$LOCKOUT" reset --force >/dev/null 2>&1
js=$(LOCKOUT_SCOPE=empty_scope "$LOCKOUT" status --all --json)
if json_well_formed "$js" && [ "${js%\"jobs\":[]\}}" != "$js" ]; then ok
else bad "expected an empty jobs array, got: $js"; fi

# ------------------------------------------------------------- control -----

scope limits
start "limit persists for the scope"
"$LOCKOUT" limit 4 >/dev/null
check "$("$LOCKOUT" limit)" 4

start "LOCKOUT_LIMIT overrides the stored limit"
check "$(LOCKOUT_LIMIT=2 "$LOCKOUT" limit)" 2

start "rejects a nonsense limit"
"$LOCKOUT" limit 0 >/dev/null 2>&1; a=$?
"$LOCKOUT" limit abc >/dev/null 2>&1; b=$?
[ "$a" != 0 ] && [ "$b" != 0 ] && ok || bad "limit 0 -> $a, limit abc -> $b"

scope cancelling
start "cancel stops a queued job before it runs"
ran=$TMP/cancel-marker; rm -f "$ran"
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
victim=$("$LOCKOUT" submit -q -- sh -c "touch '$ran'")
sleep 0.5
"$LOCKOUT" cancel "$victim" >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
[ ! -f "$ran" ] && ok || bad "cancelled job still ran"

start "cancel kills the whole process tree"
# A build spawns compilers; killing only the direct child leaves them running.
id=$("$LOCKOUT" submit -q -- sh -c 'sleep 47.1 & sleep 47.2')
sleep 1
"$LOCKOUT" cancel "$id" >/dev/null 2>&1
sleep 1.5
survivors=$(( $(pgrep -f 'sleep 47.1' 2>/dev/null | wc -l) + $(pgrep -f 'sleep 47.2' 2>/dev/null | wc -l) ))
pkill -f 'sleep 47.1' 2>/dev/null; pkill -f 'sleep 47.2' 2>/dev/null
check "$survivors" 0

start "cancel terminates a running job"
id=$("$LOCKOUT" submit -q -- sleep 30)
sleep 0.8
"$LOCKOUT" cancel "$id" >/dev/null 2>&1
t0=$SECONDS
"$LOCKOUT" wait "$id" >/dev/null 2>&1
took=$((SECONDS - t0))
[ "$took" -le 5 ] && ok || bad "cancel did not stop the job (waited ${took}s)"

scope signals
start "SIGTERM to a waiting client frees its slot"
"$LOCKOUT" submit -q -- sleep 1.0 >/dev/null
"$LOCKOUT" run -q -- sleep 34.9 >/dev/null 2>&1 &
waiter=$!
sleep 0.4
kill -TERM "$waiter" 2>/dev/null
wait "$waiter" 2>/dev/null; rc=$?
pkill -f 'sleep 34.9' 2>/dev/null
"$LOCKOUT" wait >/dev/null 2>&1
q=$("$LOCKOUT" status --json | sed 's/.*"queued":\([0-9]*\).*/\1/')
[ "$rc" = 143 ] && [ "$q" = 0 ] && ok || bad "rc=$rc queued=$q"

# ------------------------------------------------------------ retention ----

scope retention
start "keeps finished jobs inside the retention window"
"$LOCKOUT" run -q -- true >/dev/null 2>&1
before=$(LOCKOUT_RETENTION=3600 "$LOCKOUT" status --all --json | grep -c '"id"')
[ "$before" -ge 1 ] && ok || bad "expected a finished job to be listed, got $before"

start "prunes finished jobs past the retention window"
sleep 1.2   # retention is in whole seconds; the job must be measurably old
LOCKOUT_RETENTION=0 "$LOCKOUT" reap >/dev/null 2>&1
after=$(LOCKOUT_RETENTION=3600 "$LOCKOUT" status --all --json | grep -c '"id"')
[ "$after" -lt "$before" ] && ok || bad "before=$before after=$after (nothing pruned)"

start "retention never prunes a live job"
"$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.4
LOCKOUT_RETENTION=0 "$LOCKOUT" reap >/dev/null 2>&1
live=$("$LOCKOUT" status --json | grep -c '"id"')
"$LOCKOUT" wait >/dev/null 2>&1
check "$live" 1

scope exclusive

start "two jobs sharing a build dir never run at once"
# Cargo locks its target dir, so admitting both only parks one on a lock while
# it holds a slot. Limit 2 proves the constraint is the resource, not the count.
"$LOCKOUT" limit 2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-a "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.3
CARGO_TARGET_DIR=/tmp/lockout-excl-a "$LOCKOUT" submit -q -- sleep 0.2 >/dev/null
sleep 0.3
both=$("$LOCKOUT" status --json | grep -o '"state":"running"' | grep -c running)
"$LOCKOUT" wait >/dev/null 2>&1
check "$both" 1

start "distinct build dirs still run in parallel"
"$LOCKOUT" limit 2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-b "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-c "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.5
par=$("$LOCKOUT" status --json | grep -o '"state":"running"' | grep -c running)
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
check "$par" 2

start "a job blocked on a build dir says so"
"$LOCKOUT" limit 2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-d "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.3
CARGO_TARGET_DIR=/tmp/lockout-excl-d "$LOCKOUT" submit -q -- sleep 0.2 >/dev/null
sleep 0.3
said=$("$LOCKOUT" status --json | grep -o 'waiting on build dir' | wc -l | tr -d ' ')
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
[ "$said" -ge 1 ] && ok || bad "expected a blocked job to explain its wait, got $said"

start "a blocked resource does not stall unrelated jobs"
# The head of the queue may be waiting on a directory it cannot have. Everything
# behind it that needs a different directory must still start.
"$LOCKOUT" limit 2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-e "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.2
CARGO_TARGET_DIR=/tmp/lockout-excl-e "$LOCKOUT" submit -q -- sleep 0.2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-excl-f "$LOCKOUT" submit -q -- sleep 1.5 >/dev/null
sleep 0.5
running=$("$LOCKOUT" status --json | grep -o '"state":"running"' | grep -c running)
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
check "$running" 2

scope dedupe

start "an identical queued job is collapsed rather than run twice"
# Safe only because the twin has not started: it has read nothing, so whenever
# it runs it sees the tree both callers asked about.
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-dd "$LOCKOUT" submit -q -- true >/dev/null
sleep 0.2
CARGO_TARGET_DIR=/tmp/lockout-dd "$LOCKOUT" run -q -- true >/dev/null 2>&1
made=$("$LOCKOUT" status --all --json | grep -o '"command":"true"' | wc -l | tr -d ' ')
"$LOCKOUT" wait >/dev/null 2>&1
check "$made" 1

start "differing RUSTFLAGS are not the same job"
# Identical command text, opposite verdicts on identical source. Collapsing
# these would reintroduce exactly the bug this queue exists to prevent.
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-dd2 "$LOCKOUT" submit -q -- echo lint >/dev/null
sleep 0.2
CARGO_TARGET_DIR=/tmp/lockout-dd2 RUSTFLAGS="-D warnings" "$LOCKOUT" submit -q -- echo lint >/dev/null
kept=$("$LOCKOUT" status --all --json | grep -o '"command":"echo lint"' | wc -l | tr -d ' ')
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
check "$kept" 2

start "--no-dedupe forces a second run"
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
CARGO_TARGET_DIR=/tmp/lockout-dd3 "$LOCKOUT" submit -q -- echo forced >/dev/null
sleep 0.2
CARGO_TARGET_DIR=/tmp/lockout-dd3 "$LOCKOUT" run -q --no-dedupe -- echo forced >/dev/null 2>&1
forced=$("$LOCKOUT" status --all --json | grep -o '"command":"echo forced"' | wc -l | tr -d ' ')
"$LOCKOUT" wait >/dev/null 2>&1
check "$forced" 2

scope where

start "--path names the crate a job came from"
# A column of absolute paths is mostly redundant prefix; the crate is what
# identifies a job to a reader scanning the queue.
crate=$(mktemp -d)
printf '[package]\nname = "widget-forge"\nversion = "0.1.0"\n' > "$crate/Cargo.toml"
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
( cd "$crate" && "$LOCKOUT" submit -q -- echo hi >/dev/null )
sleep 0.3
named=$("$LOCKOUT" status --path | grep -c 'widget-forge')
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
rm -rf "$crate"
[ "$named" -ge 1 ] && ok || bad "expected the crate name in --path output"

start "--path falls back to the directory when there is no crate"
plain=$(mktemp -d)
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 1.2 >/dev/null
( cd "$plain" && "$LOCKOUT" submit -q -- echo hi >/dev/null )
sleep 0.3
fell=$("$LOCKOUT" status --path | grep -c "$(basename "$plain")")
"$LOCKOUT" cancel all >/dev/null 2>&1
"$LOCKOUT" wait >/dev/null 2>&1
rm -rf "$plain"
[ "$fell" -ge 1 ] && ok || bad "expected the cwd when no Cargo.toml names a package"

start "status without --path is unchanged"
"$LOCKOUT" limit 1 >/dev/null
"$LOCKOUT" submit -q -- sleep 0.8 >/dev/null
sleep 0.2
head=$("$LOCKOUT" status | sed -n '2p')
"$LOCKOUT" wait >/dev/null 2>&1
case $head in *WHERE*) bad "WHERE leaked into default output" ;; *) ok ;; esac

# ---------------------------------------------------------------------------

echo
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
