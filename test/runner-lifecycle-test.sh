#!/bin/bash
# Lifecycle and process-boundary tests for the runner: supervisor outcomes,
# descriptor isolation, environment knobs, loader round-trips, lock scope and
# failure reporting. Everything runs in a disposable fixture.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/bin/omachord"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-lifecycle-test.XXXXXX")
export TEST_ROOT
cd "$ROOT"

cleanup() {
  local pid
  for pid in $(jobs -p); do kill "$pid" 2>/dev/null || true; done
  wait 2>/dev/null || true
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS: %s\n' "$1"
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-expected '$2', got '$1'}"
}

wait_for_file() {
  for _ in {1..1000}; do
    [[ -e $1 ]] && return 0
    sleep 0.01
  done
  fail "${2:-$1 did not appear before the timeout}"
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/data" "$TEST_ROOT/runtime" "$TEST_ROOT/tmp"
: >"$TEST_ROOT/bindings.txt"

cat >"$TEST_ROOT/bin/omarchy" <<'STUB'
#!/bin/bash
case "${1:-} ${2:-} ${3:-}" in
  "menu keybindings --print") cat "$TEST_ROOT/bindings.txt" ;;
  "commands --json ") printf '%s\n' '{"commands":[]}' ;;
  *) printf '%s\n' "$*" >>"$TEST_ROOT/omarchy.log" ;;
esac
STUB

cat >"$TEST_ROOT/bin/hyprctl" <<'STUB'
#!/bin/bash
case ${1:-} in
  monitors) printf '%s\n' '[{"name":"DP-1","make":"Fixture","model":"Display","serial":"fixture","focused":true,"disabled":false,"dpmsStatus":true}]' ;;
  configerrors)
    if [[ -f $TEST_ROOT/error-after-reload && -f $TEST_ROOT/reloaded ]]; then
      printf '%s\n' 'generated configuration error'
    fi
    ;;
  reload) touch "$TEST_ROOT/reloaded" ;;
  *) exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/omarchy-shell" <<'STUB'
#!/bin/bash
state="$TEST_ROOT/shell-state"
mkdir -p "$state"
[[ ${1:-} != -q ]] || shift
case "${1:-} ${2:-}" in
  "notifications isDnd") if [[ -f $state/dnd ]]; then echo on; else echo off; fi ;;
  "notifications setDnd")
    if [[ ${3:-} == on ]]; then touch "$state/dnd"; else rm -f "$state/dnd"; fi
    echo "${3:-}"
    ;;
  *) echo "Target not found." >&2; exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/omarchy-theme-set" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >>"$TEST_ROOT/theme.log"
"$OMACHORD_TEST_RUNNER" trigger hook theme-set "$1" >>"$TEST_ROOT/theme-hook.log" 2>&1 || true
STUB

cat >"$TEST_ROOT/bin/detached-theme-set" <<'STUB'
#!/bin/bash
# Leaves a descendant that outlives the runner which started it.
( sleep 0.6; "$OMACHORD_TEST_RUNNER" trigger hook theme-set late >"$TEST_ROOT/detached-hook.json" 2>&1 ) \
  </dev/null >/dev/null 2>&1 &
STUB

cat >"$TEST_ROOT/bin/mark" <<'STUB'
#!/bin/bash
printf '%s\n' "${1:-}" >>"$TEST_ROOT/marks.log"
STUB

cat >"$TEST_ROOT/bin/list-fds" <<'STUB'
#!/bin/bash
ls /proc/self/fd | tr '\n' ' ' >"$TEST_ROOT/fds.txt"
STUB

cat >"$TEST_ROOT/bin/dump-env" <<'STUB'
#!/bin/bash
env | grep '^OMACHORD_' | sort >"$TEST_ROOT/env.txt" || true
head -c 20000 /dev/zero | tr '\0' x
STUB

cat >"$TEST_ROOT/bin/hold" <<'STUB'
#!/bin/bash
touch "$TEST_ROOT/$1.started"
while [[ ! -e $TEST_ROOT/$1.release ]]; do sleep 0.01; done
STUB

chmod +x "$TEST_ROOT/bin"/*

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export TMPDIR="$TEST_ROOT/tmp"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin"
export OMACHORD_TEST_RUNNER="$RUNNER"
unset OMACHORD_ACTION_TIMEOUT OMACHORD_CONTROL_TIMEOUT OMACHORD_LOCK_TIMEOUT OMACHORD_BULK_CLEANUP
HYPR_DIR="$HOME/.config/hypr"
OMARCHY_DIR="$HOME/.config/omarchy"
CONFIG_PATH="$OMARCHY_DIR/omachord.json"
STATE_DIR="$XDG_STATE_HOME/omarchy/omachord"
BINDINGS="$HYPR_DIR/bindings.lua"
LOADER='require("default.hypr.require_optional").module("hypr.omachord") -- Oma Chord managed loader'
mkdir -p "$HOME" "$HYPR_DIR" "$OMARCHY_DIR/plugins"
ln -s "$ROOT" "$OMARCHY_DIR/plugins/anothadev.omachord"

apply_config() {
  local revision
  revision=$("$RUNNER" config snapshot | jq -er '.revision')
  printf '%s\n' "$1" | "$RUNNER" config apply "$revision"
}

routine() {
  # routine <id> <actions-json> [extra-json]
  jq -cn --arg id "$1" --argjson actions "$2" --argjson extra "${3:-{\}}" \
    '{id:$id,name:$id,enabled:true,triggers:[],actions:$actions} + $extra'
}

config_of() {
  jq -cn '{version:1,routines:$ARGS.positional}' --jsonargs "$@"
}

apply_config "$(config_of \
  "$(routine killed '[{"type":"shell","command":"kill -KILL $$"}]')" \
  "$(routine exit124 '[{"type":"shell","command":"echo own-status; exit 124"}]')" \
  "$(routine slow '[{"type":"exec","program":"/usr/bin/sleep","args":["5"]}]')" \
  "$(routine fds '[{"type":"exec","program":"list-fds","args":[]}]')" \
  "$(routine env '[{"type":"exec","program":"dump-env","args":[]}]')")" | jq -e '.ok' >/dev/null

# --- Supervisor outcomes (timeouts are reported only when the deadline fired)
result=$("$RUNNER" run killed test || true)
jq -e '.code == "action-failed" and .error == "Action was killed (signal 9)"' <<<"$result" >/dev/null \
  || fail "a SIGKILLed action was misreported: $result"
result=$("$RUNNER" run exit124 test || true)
jq -e '.code == "action-failed" and (.error | test("timed out") | not) and (.error | test("own-status"))' \
  <<<"$result" >/dev/null || fail "an action exiting 124 was reported as a timeout: $result"
result=$(OMACHORD_ACTION_TIMEOUT=0.2s "$RUNNER" run slow test || true)
jq -e '.error == "Action timed out after 0.2s"' <<<"$result" >/dev/null \
  || fail "a real timeout was not reported: $result"
pass "supervisor outcome attribution"

# --- Actions inherit only stdin/stdout/stderr (ls itself adds fd 3)
"$RUNNER" run fds test | jq -e '.ok' >/dev/null
assert_eq "$(cat "$TEST_ROOT/fds.txt")" "0 1 2 3 " "actions inherited runner descriptors"
pass "action descriptor isolation"

# --- Internal knobs are not honored from the ambient environment
result=$(OMACHORD_CAPTURE_MODE=head OMACHORD_CAPTURE_LIMIT=1 OMACHORD_BULK_CLEANUP=1 "$RUNNER" run env test)
jq -e '.ok' <<<"$result" >/dev/null || fail "ambient capture knobs changed an action: $result"
if grep -E '^OMACHORD_(CAPTURE_MODE|CAPTURE_LIMIT|BULK_CLEANUP)=' "$TEST_ROOT/env.txt"; then
  fail "internal knobs leaked into the action environment"
fi
for assignment in OMACHORD_ACTION_TIMEOUT=bogus OMACHORD_ACTION_TIMEOUT=0s \
    OMACHORD_CONTROL_TIMEOUT='5 s' OMACHORD_LOCK_TIMEOUT=ten; do
  result=$(env "$assignment" "$RUNNER" run fds test || true)
  jq -e '.code == "invalid-environment"' <<<"$result" >/dev/null \
    || fail "$assignment was not rejected clearly: $result"
done
OMACHORD_ACTION_TIMEOUT=1.5m OMACHORD_LOCK_TIMEOUT=2.5 "$RUNNER" run fds test | jq -e '.ok' >/dev/null
pass "environment knob validation and isolation"

# --- Connect/Disconnect leave bindings.lua byte-identical
result=$("$RUNNER" connect) || fail "initial connect failed: $result"
result=$("$RUNNER" disconnect) || fail "initial disconnect failed: $result"
check_round_trip() {
  local label=$1 original=$2 cycle
  printf '%s' "$original" >"$BINDINGS"
  for cycle in 1 2 3; do
    "$RUNNER" connect | jq -e '.ok and .connected' >/dev/null || fail "$label: connect failed"
    grep -Fqx -- "$LOADER" "$BINDINGS" || fail "$label: connect did not add the loader"
    "$RUNNER" disconnect | jq -e '.ok and (.connected | not)' >/dev/null || fail "$label: disconnect failed"
    cmp -s <(printf '%s' "$original") "$BINDINGS" \
      || fail "$label: cycle $cycle changed bindings.lua: $(od -c "$BINDINGS" | head -5)"
  done
}
check_round_trip "terminated file" $'-- user bindings\nbind("a")\n'
check_round_trip "unterminated file" $'-- user bindings\nbind("a")'
check_round_trip "empty file" ''
check_round_trip "user blank lines" $'bind("a")\n\n\n'
check_round_trip "leading blank line" $'\nbind("a")\n'
# A user line after the loader keeps its place; only the loader goes.
printf '%s' $'bind("a")\n' >"$BINDINGS"
"$RUNNER" connect | jq -e '.ok' >/dev/null
printf '%s\n' 'bind("b")' >>"$BINDINGS"
"$RUNNER" disconnect | jq -e '.ok' >/dev/null
cmp -s <(printf '%s' $'bind("a")\n\nbind("b")\n') "$BINDINGS" \
  || fail "loader removal disturbed user lines after the loader: $(od -c "$BINDINGS" | head -5)"
# Old releases left one extra blank line per cycle. Model such a connected
# file: disconnect removes the loader and one separator, nothing more.
printf '%s\n' 'bind("a")' >"$BINDINGS"
"$RUNNER" connect | jq -e '.ok' >/dev/null
printf '%s\n' 'bind("a")' '' '' '' "$LOADER" >"$BINDINGS"
"$RUNNER" disconnect | jq -e '.ok' >/dev/null
cmp -s <(printf '%s' $'bind("a")\n\n\n') "$BINDINGS" \
  || fail "legacy accumulated blank lines were not handled: $(od -c "$BINDINGS" | head -5)"
pass "loader connect/disconnect round trip"

# --- A FIFO swapped in for bindings.lua while Connect holds the lock fails
# the transaction promptly instead of blocking the reader forever.
mkdir -p "$TEST_ROOT/swap-bin"
cat >"$TEST_ROOT/swap-bin/stat" <<'STUB'
#!/bin/bash
if [[ -f $TEST_ROOT/swap-fifo && ${1:-} == -c && ${2:-} == %a && ${3:-} == "$SWAP_TARGET" ]]; then
  rm -f "$TEST_ROOT/swap-fifo"
  mode=$(/usr/bin/stat -c %a "$3")
  rm -f "$3"
  mkfifo -m "$mode" "$3"
  printf '%s\n' "$mode"
  exit 0
fi
exec /usr/bin/stat "$@"
STUB
chmod +x "$TEST_ROOT/swap-bin/stat"
printf '%s\n' 'bind("a")' >"$BINDINGS"
touch "$TEST_ROOT/swap-fifo"
start=$(date +%s%3N)
status=0
SWAP_TARGET=$BINDINGS PATH="$TEST_ROOT/swap-bin:$PATH" timeout 20s "$RUNNER" connect >"$TEST_ROOT/fifo.json" || status=$?
elapsed=$(($(date +%s%3N) - start))
[[ ! -e $TEST_ROOT/swap-fifo ]] || fail "the FIFO swap was not exercised"
((status != 0 && status != 124)) || fail "Connect did not fail cleanly on a swapped FIFO (status $status)"
((elapsed < 10000)) || fail "Connect blocked ${elapsed}ms on a swapped FIFO"
jq -e '.ok == false' "$TEST_ROOT/fifo.json" >/dev/null || fail "FIFO swap did not report a failure"
rm -f "$BINDINGS"
printf '%s\n' 'bind("a")' >"$BINDINGS"
pass "nonblocking reads of user-controlled integration files"

# --- Only the newest bindings backups plus the original are kept
backups="$STATE_DIR/backups"
rm -f "$backups"/bindings.lua.*
printf '%s\n' original >"$backups/bindings.lua.00000000000000aa"
touch -d '2019-01-01' "$backups/bindings.lua.00000000000000aa"
for index in $(seq 1 15); do
  name=$(printf 'bindings.lua.%016x' "$((index + 256))")
  printf '%s\n' "$index" >"$backups/$name"
  touch -d "2020-01-$(printf '%02d' "$index")" "$backups/$name"
done
chmod 600 "$backups"/bindings.lua.*
"$RUNNER" connect | jq -e '.ok' >/dev/null
assert_eq "$(find "$backups" -maxdepth 1 -name 'bindings.lua.*' | wc -l)" 11 "backups were not pruned"
[[ $(cat "$backups/bindings.lua.00000000000000aa") == original ]] || fail "the original backup was pruned"
[[ ! -e $backups/$(printf 'bindings.lua.%016x' 257) ]] || fail "an old intermediate backup was kept"
[[ -e $backups/$(printf 'bindings.lua.%016x' 271) ]] || fail "a recent backup was pruned"
"$RUNNER" disconnect | jq -e '.ok' >/dev/null
assert_eq "$(find "$backups" -maxdepth 1 -name 'bindings.lua.*' | wc -l)" 11 "backups grew past the limit"
pass "bindings backup retention"

printf 'Runner lifecycle tests passed.\n'
