#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SUPERVISOR="$ROOT/bin/omachord-action-supervisor"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-supervisor-test.XXXXXX")
KEEPER_PID=""

cleanup() {
  [[ -z $KEEPER_PID ]] || kill "$KEEPER_PID" 2>/dev/null || true
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

runner_pid=$BASHPID
runner_start=$(awk '{print $22}' "/proc/$runner_pid/stat")

# The runner keeps the supervisor's stdin open for the whole action; EOF is
# cancellation. Hold a pipe writer open the same way for each call.
exec {keeper}< <(exec sleep 600)
KEEPER_PID=$!

STATUS=0
supervise() {
  local control=$1 output=$2 duration=$3
  shift 3
  STATUS=0
  "$SUPERVISOR" "$runner_pid" "$runner_start" "$control" "$duration" \
    --capture tail 4096 "$output" -- "$@" <&"$keeper" >/dev/null 2>"$TEST_ROOT/supervisor.err" \
    || STATUS=$?
}

new_control() {
  local control
  control=$(mktemp -d "$TEST_ROOT/control.XXXXXX")
  printf '%s\n' "$control"
}

# The capture mode is the only mode; a missing --capture is rejected.
if "$SUPERVISOR" "$runner_pid" "$runner_start" "$TEST_ROOT" 30s -- /usr/bin/true \
    <&"$keeper" >/dev/null 2>&1; then
  fail "the supervisor accepted a call without --capture"
fi
if "$SUPERVISOR" "$runner_pid" "$runner_start" "$TEST_ROOT" bogus --capture tail 64 \
    "$TEST_ROOT/bogus.out" -- /usr/bin/true <&"$keeper" >/dev/null 2>&1; then
  fail "the supervisor accepted an invalid timeout duration"
fi
printf 'PASS: supervisor argument validation\n'

# An unwritable or vanished control directory is advisory only: it must not
# turn a successful action into a failure (for example on ENOSPC).
bad_control="$TEST_ROOT/not-a-directory"
touch "$bad_control"
supervise "$bad_control/control" "$TEST_ROOT/bad.out" 30s /usr/bin/printf ok
((STATUS == 0)) || fail "an unwritable control directory failed a successful action ($STATUS)"
[[ $(cat "$TEST_ROOT/bad.out") == ok ]] || fail "output was lost with an unwritable control directory"

control=$(new_control)
ready="$TEST_ROOT/action-ready"
release="$TEST_ROOT/action-release"
"$SUPERVISOR" "$runner_pid" "$runner_start" "$control" 30s --capture tail 64 "$TEST_ROOT/vanish.out" -- \
  /usr/bin/bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.01; done; printf done' bash \
  "$ready" "$release" <&"$keeper" >/dev/null 2>&1 &
supervisor_pid=$!
for _ in {1..500}; do [[ -e $ready ]] && break; sleep 0.01; done
[[ -e $ready ]] || fail "action did not start"
rm -rf -- "$control"
touch "$release"
wait "$supervisor_pid" || fail "a removed control directory failed a successful action"
[[ $(cat "$TEST_ROOT/vanish.out") == done ]] || fail "output was lost after the control directory vanished"
printf 'PASS: control-directory loss does not fail successful actions\n'

# The outcome line distinguishes the supervisor's own deadline from an action
# that was killed or that exits with a timeout-like status by itself.
control=$(new_control)
supervise "$control" "$TEST_ROOT/timeout.out" 0.1s /usr/bin/sleep 5
((STATUS == 124)) || fail "timed-out action returned $STATUS"
[[ $(cat "$control/outcome") == timeout ]] || fail "timeout outcome was not reported"

control=$(new_control)
supervise "$control" "$TEST_ROOT/stubborn.out" 0.1s /usr/bin/bash -c 'trap "" TERM; sleep 5'
((STATUS == 137)) || fail "kill-after timeout returned $STATUS"
[[ $(cat "$control/outcome") == timeout ]] || fail "kill-after timeout was not reported as a timeout"

control=$(new_control)
supervise "$control" "$TEST_ROOT/killed.out" 30s /usr/bin/bash -c 'kill -KILL $$'
((STATUS == 137)) || fail "SIGKILLed action returned $STATUS"
[[ $(cat "$control/outcome") == "signal 9" ]] \
  || fail "a SIGKILLed action was not reported as killed: $(cat "$control/outcome")"

control=$(new_control)
supervise "$control" "$TEST_ROOT/exit124.out" 30s /usr/bin/bash -c 'exit 124'
((STATUS == 124)) || fail "exit 124 returned $STATUS"
[[ $(cat "$control/outcome") == "exit 124" ]] || fail "exit 124 was reported as a timeout"
printf 'PASS: supervisor outcome attribution\n'

# Actions receive only stdin, stdout and stderr, never the runner's locks or
# pipes. Open some extra descriptors the way the runner holds them.
control=$(new_control)
exec 7<"$TEST_ROOT/bad.out" 9<"$TEST_ROOT/bad.out" 12<"$TEST_ROOT/bad.out"
supervise "$control" "$TEST_ROOT/fds.out" 30s /usr/bin/ls /proc/self/fd
exec 7<&- 9<&- 12<&-
((STATUS == 0)) || fail "descriptor listing failed"
[[ $(tr '\n' ' ' <"$TEST_ROOT/fds.out") == "0 1 2 3 " ]] \
  || fail "the action inherited extra descriptors: $(tr '\n' ' ' <"$TEST_ROOT/fds.out")"
printf 'PASS: actions inherit only standard descriptors\n'

# EOF on stdin still cancels promptly.
control=$(new_control)
start=$(date +%s%3N)
status=0
"$SUPERVISOR" "$runner_pid" "$runner_start" "$control" 30s --capture tail 64 "$TEST_ROOT/eof.out" -- \
  /usr/bin/sleep 30 </dev/null >/dev/null 2>&1 || status=$?
elapsed=$(($(date +%s%3N) - start))
((status != 0 && elapsed < 1000)) || fail "stdin EOF did not cancel the action promptly"
[[ $(cat "$control/outcome") == cancelled ]] || fail "cancellation outcome was not reported"
printf 'PASS: stdin EOF cancellation\n'

printf 'Action supervisor tests passed.\n'
