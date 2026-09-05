#!/bin/bash

set -euo pipefail

# Optional argument: directory for off/on/busy PNGs rendered with native Qt.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-toggle-test.XXXXXX")
LOG_FILE="$TEST_DIR/runtime.log"
trap 'rm -rf -- "$TEST_DIR"' EXIT

# Snapshot both app controls and their theme kit: never hot-reload another
# developer's edits mid-test or load the live desktop shell configuration.
cp -RL -- /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
cp -RL -- /usr/share/omarchy/shell/Ui "$TEST_DIR/Ui"
for file in PendingSwitch.qml PendingToggle.qml; do
  cp -- "$ROOT/$file" "$TEST_DIR/$file"
done
cp -- "$ROOT/test/qml-runtime/toggles.qml" "$TEST_DIR/shell.qml"

export OMACHORD_TOGGLE_RENDER_OUT="${1:-}"
if [[ -n $OMACHORD_TOGGLE_RENDER_OUT ]]; then
  mkdir -p -- "$OMACHORD_TOGGLE_RENDER_OUT"
  OMACHORD_TOGGLE_RENDER_OUT=$(cd -- "$OMACHORD_TOGGLE_RENDER_OUT" && pwd)
fi

if ! QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    timeout 30 quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
    >"$LOG_FILE" 2>&1; then
  cat "$LOG_FILE" >&2
  printf 'FAIL: pending toggle runtime process\n' >&2
  exit 1
fi

if ! grep -q 'OMACHORD_QML_TOGGLE_TEST_PASS' "$LOG_FILE" \
    || grep -Eq 'OMACHORD_QML_TOGGLE_TEST_FAIL|Failed to load|TypeError|ReferenceError|Binding loop detected|Unable to assign|Cannot set activeFocusOnTab' "$LOG_FILE"; then
  cat "$LOG_FILE" >&2
  printf 'FAIL: pending toggle runtime regression\n' >&2
  exit 1
fi

grep 'OMACHORD_QML_TOGGLE_TEST_PASS\|OMACHORD_TOGGLE_RENDER_SAVED' "$LOG_FILE"

if [[ -n $OMACHORD_TOGGLE_RENDER_OUT ]]; then
  for state in off on busy; do
    [[ -s $OMACHORD_TOGGLE_RENDER_OUT/$state.png ]] || {
      printf 'FAIL: missing toggle render: %s\n' "$state" >&2
      exit 1
    }
  done
fi
