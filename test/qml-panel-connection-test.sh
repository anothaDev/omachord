#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-panel-connection-test.XXXXXX")
runtime_pid=""
cleanup() {
  if [[ -n $runtime_pid ]]; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

cp -RL -- /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
cp -RL -- /usr/share/omarchy/shell/Ui "$TEST_DIR/Ui"
cp -- "$ROOT"/*.qml "$ROOT"/*.js "$TEST_DIR/"
mkdir -p "$TEST_DIR/theme" "$TEST_DIR/bin"
# A public Panel refresh must never invoke the live shell during these tests.
printf '#!/bin/bash\nprintf "[]\\n"\n' >"$TEST_DIR/bin/omarchy-shell"
printf '#!/bin/bash\nexit 0\n' >"$TEST_DIR/bin/omarchy-theme-list"
chmod +x "$TEST_DIR/bin/omarchy-shell" "$TEST_DIR/bin/omarchy-theme-list"
export PATH="$TEST_DIR/bin:$PATH"
export OMACHORD_QML_TEST_DIR="$TEST_DIR"
cp -- "$ROOT/test/qml-runtime/fake-panel-transition-runner" "$TEST_DIR/runner"
chmod +x "$TEST_DIR/runner"
export OMACHORD_RUNNER_PATH="$TEST_DIR/runner"
export OMACHORD_THEME_DIR="$TEST_DIR/theme"
export OMACHORD_THEME_NAME_FILE="$TEST_DIR/theme.name"
for fixture in panel-connection.qml panel-fallback.qml; do
  cp -- "$ROOT/test/qml-runtime/$fixture" "$TEST_DIR/shell.qml"
  : >"$TEST_DIR/transition-calls.log"
  QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color \
    >"$TEST_DIR/runtime.log" 2>&1 &
  runtime_pid=$!
  for _ in {1..3000}; do
    if grep -q 'OMACHORD_QML_TEST_' "$TEST_DIR/runtime.log"; then break; fi
    kill -0 "$runtime_pid" 2>/dev/null || break
    sleep 0.01
  done
  kill -TERM "$runtime_pid" 2>/dev/null || true
  wait "$runtime_pid" 2>/dev/null || true
  runtime_pid=""
  if ! grep -q 'OMACHORD_QML_TEST_PASS' "$TEST_DIR/runtime.log" \
    || grep -q 'OMACHORD_QML_TEST_FAIL\|TypeError\|ReferenceError\|Binding loop detected\|Unable to assign' "$TEST_DIR/runtime.log"; then
    cat "$TEST_DIR/runtime.log" >&2
    printf 'FAIL: panel connection transition regression (%s)\n' "$fixture" >&2
    exit 1
  fi
  grep 'OMACHORD_QML_TEST_PASS' "$TEST_DIR/runtime.log"
done
printf 'Panel connection transition tests passed.\n'
