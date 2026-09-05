#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-panel-enable-test.XXXXXX")
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

ln -s /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
ln -s /usr/share/omarchy/shell/Ui "$TEST_DIR/Ui"
for file in "$ROOT"/*.qml "$ROOT"/*.js; do
  # Snapshot the sources so another developer saving this worktree cannot
  # make Quickshell hot-reload halfway through this signal-ordering test.
  cp -- "$file" "$TEST_DIR/$(basename -- "$file")"
done
cp -- "$ROOT/test/qml-runtime/panel-enable-batching.qml" "$TEST_DIR/shell.qml"
: >"$TEST_DIR/panel-calls.log"
: >"$TEST_DIR/apply-count"
mkdir -p "$TEST_DIR/theme"

export OMACHORD_QML_TEST_DIR="$TEST_DIR"
export OMACHORD_RUNNER_PATH="$ROOT/test/qml-runtime/fake-panel-runner"
export OMACHORD_THEME_DIR="$TEST_DIR/theme"
export OMACHORD_THEME_NAME_FILE="$TEST_DIR/theme.name"

QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
  >"$LOG_FILE" 2>&1 &
runtime_pid=$!

for _ in {1..2000}; do
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
  printf 'FAIL: panel enable batching runtime regression\n' >&2
  exit 1
fi

printf 'Panel enable batching runtime test passed.\n'
