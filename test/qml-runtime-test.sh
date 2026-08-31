#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-qml-test.XXXXXX")
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

cp -- "$ROOT/test/qml-runtime/shell.qml" "$TEST_DIR/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
ln -s /usr/share/omarchy/shell/Ui "$TEST_DIR/Ui"
for file in RoutineEditor.qml ActionCard.qml ChoicePicker.qml ShortcutRecorder.qml PlainTextButton.qml Model.js Conditions.js; do
  ln -s "$ROOT/$file" "$TEST_DIR/$file"
done

QT_QPA_PLATFORM=offscreen quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
  >"$LOG_FILE" 2>&1 &
runtime_pid=$!

for _ in {1..500}; do
  if grep -q 'OMACHORD_QML_TEST_' "$LOG_FILE"; then break; fi
  kill -0 "$runtime_pid" 2>/dev/null || break
  sleep 0.01
done

if ! grep -q 'OMACHORD_QML_TEST_PASS' "$LOG_FILE" \
  || grep -q 'OMACHORD_QML_TEST_FAIL' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  printf 'FAIL: QML editor staging regression\n' >&2
  exit 1
fi

printf 'QML runtime interaction tests passed.\n'
