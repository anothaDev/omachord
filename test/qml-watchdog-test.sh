#!/bin/bash
# Service and Panel runner deadlines against a runner that never exits.
# Everything runs offscreen in a private directory with an isolated
# environment; no live shell, configuration, or desktop state is touched.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-watchdog-test.XXXXXX")
runtime_pid=""

# Hung fakes exec "sleep 3600"; only those carrying this test's directory
# in their environment are ours.
hung_runners() {
  local pid
  for pid in $(pgrep -x sleep 2>/dev/null || true); do
    if tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -qxF "OMACHORD_QML_TEST_DIR=$TEST_DIR"; then
      printf '%s\n' "$pid"
    fi
  done
}

cleanup() {
  if [[ -n $runtime_pid ]]; then
    kill -TERM "$runtime_pid" 2>/dev/null || true
    wait "$runtime_pid" 2>/dev/null || true
  fi
  # A fixture failure must not leave a hung fake runner behind.
  hung_runners | xargs -r kill -KILL 2>/dev/null || true
  rm -rf -- "$TEST_DIR"
}
trap cleanup EXIT

cp -RL -- /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
cp -RL -- /usr/share/omarchy/shell/Ui "$TEST_DIR/Ui"
cp -- "$ROOT"/*.qml "$ROOT"/*.js "$TEST_DIR/"
mkdir -p "$TEST_DIR"/{home,config,state/omarchy/toggles,state/omachord,data,cache,runtime,tmp,theme,bin}
chmod 700 "$TEST_DIR/runtime"
# The Panel must never reach the live shell through a helper on PATH.
printf '#!/bin/bash\nprintf "[]\\n"\n' >"$TEST_DIR/bin/omarchy-shell"
printf '#!/bin/bash\nexit 0\n' >"$TEST_DIR/bin/omarchy-theme-list"
cp -- "$ROOT/test/qml-runtime/fake-hang-runner" "$TEST_DIR/bin/runner"
cp -- "$ROOT/test/qml-runtime/fake-runner-grammar" "$TEST_DIR/bin/fake-runner-grammar"
chmod +x "$TEST_DIR/bin/"*

for fixture in service-hang.qml panel-hang.qml; do
  cp -- "$ROOT/test/qml-runtime/$fixture" "$TEST_DIR/shell.qml"
  rm -f -- "$TEST_DIR"/hang-* "$TEST_DIR"/ignore-term-*
  : >"$TEST_DIR/hang-calls.log"
  log="$TEST_DIR/runtime-$fixture.log"
  env -i PATH="$TEST_DIR/bin:/usr/bin:/bin" LANG=C HOME="$TEST_DIR/home" \
    XDG_CONFIG_HOME="$TEST_DIR/config" XDG_STATE_HOME="$TEST_DIR/state" XDG_DATA_HOME="$TEST_DIR/data" \
    XDG_CACHE_HOME="$TEST_DIR/cache" XDG_RUNTIME_DIR="$TEST_DIR/runtime" TMPDIR="$TEST_DIR/tmp" \
    OMACHORD_QML_TEST_DIR="$TEST_DIR" OMACHORD_RUNNER_PATH="$TEST_DIR/bin/runner" \
    OMACHORD_CONFIG_FILE="$TEST_DIR/config/omachord.json" OMACHORD_STATE_DIR="$TEST_DIR/state/omachord" \
    OMACHORD_THEME_DIR="$TEST_DIR/theme" OMACHORD_THEME_NAME_FILE="$TEST_DIR/theme.name" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TEST_DIR/no-session-bus" DBUS_SYSTEM_BUS_ADDRESS="unix:path=$TEST_DIR/no-system-bus" \
    QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
    /usr/bin/quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color >"$log" 2>&1 &
  runtime_pid=$!
  for _ in {1..3000}; do
    if grep -q 'OMACHORD_QML_TEST_' "$log"; then break; fi
    kill -0 "$runtime_pid" 2>/dev/null || break
    sleep 0.01
  done
  kill -TERM "$runtime_pid" 2>/dev/null || true
  wait "$runtime_pid" 2>/dev/null || true
  runtime_pid=""
  if ! grep -q OMACHORD_QML_TEST_PASS "$log" \
    || grep -q 'OMACHORD_QML_TEST_FAIL\|TypeError\|ReferenceError\|Binding loop detected\|Unable to assign' "$log"; then
    cat "$log" "$TEST_DIR/hang-calls.log" >&2
    printf 'FAIL: runner watchdog regression (%s)\n' "$fixture" >&2
    exit 1
  fi
  if [[ -n $(hung_runners) ]]; then
    printf 'FAIL: a hung runner outlived its watchdog (%s)\n' "$fixture" >&2
    exit 1
  fi
  grep OMACHORD_QML_TEST_PASS "$log"
done

printf 'Runner watchdog tests passed.\n'
