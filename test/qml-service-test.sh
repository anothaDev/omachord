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
cp -- "$ROOT/test/qml-runtime/service.qml" "$TEST_DIR/shell.qml"
for file in Service.qml Conditions.js; do
  ln -s "$ROOT/$file" "$TEST_DIR/$file"
done
: >"$TEST_DIR/runner-calls.log"
touch "$TEST_DIR/delay-logs" "$TEST_DIR/hold-deactivate"

export OMACHORD_QML_TEST_DIR="$TEST_DIR"
export OMACHORD_RUNNER_PATH="$ROOT/test/qml-runtime/fake-runner"
export OMACHORD_STATE_DIR="$TEST_DIR/state/omarchy/omachord"
export OMACHORD_CONFIG_FILE="$TEST_DIR/home/omachord.json"
export XDG_STATE_HOME="$TEST_DIR/state"

QT_QPA_PLATFORM=offscreen quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
  >"$LOG_FILE" 2>&1 &
runtime_pid=$!

for _ in {1..2500}; do
  if grep -q 'OMACHORD_QML_TEST_' "$LOG_FILE"; then break; fi
  kill -0 "$runtime_pid" 2>/dev/null || break
  sleep 0.01
done

if ! grep -q 'OMACHORD_QML_TEST_PASS' "$LOG_FILE" \
  || grep -q 'OMACHORD_QML_TEST_FAIL' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  printf 'FAIL: service runtime regression\n' >&2
  exit 1
fi

printf 'Service runtime test passed.\n'
