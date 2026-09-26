#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-brightness-blocked.XXXXXX")
runtime_pid=""
cleanup() {
  if [[ -n $runtime_pid ]]; then kill -TERM "$runtime_pid" 2>/dev/null || true; wait "$runtime_pid" 2>/dev/null || true; fi
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT
cp -RL /usr/share/omarchy/shell/Commons /usr/share/omarchy/shell/Ui "$TEST_DIR/"
cp "$ROOT"/*.qml "$ROOT"/*.js "$TEST_DIR/"
cp "$ROOT/test/qml-runtime/brightness-blocked.qml" "$TEST_DIR/shell.qml"
cp "$ROOT/test/qml-runtime/fake-brightness-runner" "$TEST_DIR/runner"
chmod +x "$TEST_DIR/runner"
mkdir -p "$TEST_DIR"/{home,config,state/omarchy/toggles,data,cache,runtime,tmp,theme,bin}
chmod 700 "$TEST_DIR/runtime"
printf '#!/bin/bash\nprintf "[]\\n"\n' >"$TEST_DIR/bin/omarchy-shell"
printf '#!/bin/bash\nexit 0\n' >"$TEST_DIR/bin/omarchy-theme-list"
chmod +x "$TEST_DIR/bin/"*
: >"$TEST_DIR/calls.log"
env -i PATH="$TEST_DIR/bin:/usr/bin:/bin" LANG=C HOME="$TEST_DIR/home" \
  XDG_CONFIG_HOME="$TEST_DIR/config" XDG_STATE_HOME="$TEST_DIR/state" XDG_DATA_HOME="$TEST_DIR/data" \
  XDG_CACHE_HOME="$TEST_DIR/cache" XDG_RUNTIME_DIR="$TEST_DIR/runtime" TMPDIR="$TEST_DIR/tmp" \
  OMACHORD_QML_TEST_DIR="$TEST_DIR" OMACHORD_RUNNER_PATH="$TEST_DIR/runner" \
  OMACHORD_CONFIG_FILE="$TEST_DIR/config/omachord.json" OMACHORD_STATE_DIR="$TEST_DIR/state/omachord" \
  OMACHORD_THEME_DIR="$TEST_DIR/theme" OMACHORD_THEME_NAME_FILE="$TEST_DIR/theme.name" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_DIR/no-session-bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$TEST_DIR/no-system-bus" \
  QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  /usr/bin/quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color >"$TEST_DIR/runtime.log" 2>&1 &
runtime_pid=$!
for _ in {1..3000}; do
  if grep -q 'OMACHORD_QML_TEST_' "$TEST_DIR/runtime.log"; then break; fi
  kill -0 "$runtime_pid" 2>/dev/null || break
  sleep 0.01
done
if ! grep -q OMACHORD_QML_TEST_PASS "$TEST_DIR/runtime.log" \
  || grep -q 'OMACHORD_QML_TEST_FAIL\|TypeError\|ReferenceError\|Binding loop detected\|Unable to assign' "$TEST_DIR/runtime.log"; then
  cat "$TEST_DIR/runtime.log" "$TEST_DIR/calls.log" >&2
  exit 1
fi
printf 'Brightness blocked service/UI QML tests passed.\n'
