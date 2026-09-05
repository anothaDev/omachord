#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-service-test.XXXXXX")
LOG_FILE="$TEST_DIR/runtime.log"
runtime_pid=""

cleanup() {
  if [[ -n $runtime_pid ]]; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

mkdir -p "$TEST_DIR/state/omarchy/toggles" "$TEST_DIR/state/omarchy/omachord" "$TEST_DIR/home"
for file in Service.qml Conditions.js; do
  ln -s "$ROOT/$file" "$TEST_DIR/$file"
done
: >"$TEST_DIR/runner-calls.log"
: >"$TEST_DIR/manual-calls.log"
touch "$TEST_DIR/delay-logs" "$TEST_DIR/hold-deactivate"

export OMACHORD_QML_TEST_DIR="$TEST_DIR"
export OMACHORD_STATE_DIR="$TEST_DIR/state/omarchy/omachord"
export OMACHORD_CONFIG_FILE="$TEST_DIR/home/omachord.json"
export XDG_STATE_HOME="$TEST_DIR/state"

run_runtime_test() {
  local fixture=$1
  local runner=$2
  local label=$3

  cp -- "$ROOT/test/qml-runtime/$fixture" "$TEST_DIR/shell.qml"
  : >"$LOG_FILE"
  if [[ $runner = /* ]]; then
    export OMACHORD_RUNNER_PATH="$runner"
  else
    export OMACHORD_RUNNER_PATH="$ROOT/test/qml-runtime/$runner"
  fi
  QT_QPA_PLATFORM=offscreen quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
    >"$LOG_FILE" 2>&1 &
  runtime_pid=$!

  for _ in {1..2500}; do
    if grep -q 'OMACHORD_QML_TEST_' "$LOG_FILE"; then break; fi
    kill -0 "$runtime_pid" 2>/dev/null || break
    sleep 0.01
  done

  kill -TERM "$runtime_pid" 2>/dev/null || true
  wait "$runtime_pid" 2>/dev/null || true
  runtime_pid=""

  if ! grep -q 'OMACHORD_QML_TEST_PASS' "$LOG_FILE" \
    || grep -q 'OMACHORD_QML_TEST_FAIL' "$LOG_FILE"; then
    cat "$LOG_FILE" >&2
    printf 'FAIL: %s\n' "$label" >&2
    exit 1
  fi
}

run_runtime_test service.qml fake-runner 'service runtime regression'
run_runtime_test service-concurrency.qml fake-concurrency-runner 'service concurrency regression'

# A private executable lets the connection fixture test FailedToStart without
# changing the tracked runner or touching any user configuration.
cp -- "$ROOT/test/qml-runtime/fake-connection-runner" "$TEST_DIR/connection-runner"
chmod +x "$TEST_DIR/connection-runner"
: >"$TEST_DIR/connection-calls.log"
printf '{}\n' >"$OMACHORD_STATE_DIR/connection.json"
run_runtime_test service-connection.qml "$TEST_DIR/connection-runner" 'service connection regression'

printf 'Service runtime test passed.\n'
