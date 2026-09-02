#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SUPERVISOR="$ROOT/bin/omachord-action-supervisor"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-supervisor-test.XXXXXX")

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

runner_pid=$BASHPID
runner_start=$(awk '{print $22}' "/proc/$runner_pid/stat")
bad_control="$TEST_ROOT/not-a-directory"
touch "$bad_control"
start=$(date +%s%3N)
set +e
/usr/bin/timeout 2s "$SUPERVISOR" "$runner_pid" "$runner_start" "$bad_control/control" \
  30s -- /usr/bin/sleep 30 </dev/null >/dev/null 2>&1
status=$?
set -e
elapsed=$(($(date +%s%3N) - start))
((status != 0 && elapsed < 1000)) \
  || fail "initial marker failure did not terminate the supervisor promptly"

control="$TEST_ROOT/control"
mkdir -m 700 "$control"
ready="$TEST_ROOT/action-ready"
release="$TEST_ROOT/action-release"

"$SUPERVISOR" "$runner_pid" "$runner_start" "$control" 30s -- \
  /usr/bin/bash -c 'touch "$1"; while [[ ! -e $2 ]]; do sleep 0.01; done' bash \
  "$ready" "$release" </dev/null >/dev/null 2>&1 &
supervisor_pid=$!
timeout_pid=""
for _ in {1..500}; do
  timeout_marker=$(find "$control" -maxdepth 1 -name 'timeout.*' -print -quit 2>/dev/null || true)
  if [[ -n $timeout_marker && -e $ready ]]; then
    timeout_pid=${timeout_marker##*.}
    break
  fi
  sleep 0.01
done
[[ -n $timeout_pid ]] || fail "action supervisor did not publish its leader identity"
rm -rf -- "$control"
touch "$release"
if wait "$supervisor_pid"; then
  fail "action supervisor accepted a lost completion marker"
fi
[[ ! -e /proc/$timeout_pid ]] || fail "marker failure left the action leader unreaped"
printf 'Action supervisor failure-path tests passed.\n'
