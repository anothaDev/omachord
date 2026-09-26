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
( while [[ ! -e $TEST_ROOT/detached.release ]]; do sleep 0.01; done
  "$OMACHORD_TEST_RUNNER" trigger hook theme-set late >"$TEST_ROOT/detached-hook.tmp" 2>&1
  mv "$TEST_ROOT/detached-hook.tmp" "$TEST_ROOT/detached-hook.json" ) \
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

# --- A running routine no longer holds the config lock for its whole run
revision() { "$RUNNER" config snapshot | jq -er '.revision'; }
LOCK_CONFIG=$(config_of \
  "$(routine long-run '[{"type":"exec","program":"hold","args":["run1"]}]')" \
  "$(routine long-activate '[{"type":"dnd","value":true,"restore":true},{"type":"exec","program":"hold","args":["act1"]}]')" \
  "$(routine other '[{"type":"exec","program":"mark","args":["other"]}]')")
apply_config "$LOCK_CONFIG" | jq -e '.ok' >/dev/null
renamed() { jq -c --arg name "$1" '(.routines[] | select(.id == "other") | .name) = $name' <<<"$LOCK_CONFIG"; }

"$RUNNER" run long-run manual >"$TEST_ROOT/long-run.json" &
long_pid=$!
wait_for_file "$TEST_ROOT/run1.started" "the long stateless run did not start"
start=$(date +%s%3N)
apply_config "$(renamed "Other during run")" | jq -e '.ok' >/dev/null \
  || fail "config apply failed while a stateless routine was running"
elapsed=$(($(date +%s%3N) - start))
((elapsed < 5000)) || fail "config apply waited ${elapsed}ms for a running routine"
touch "$TEST_ROOT/run1.release"
wait "$long_pid" || fail "the long stateless run failed"
jq -e '.ok' "$TEST_ROOT/long-run.json" >/dev/null || fail "the long run reported failure"

# A mid-activation routine that an apply would orphan is serialized through
# its routine lock: the apply waits, then reports a retryable code without
# changing anything.
"$RUNNER" activate long-activate manual >"$TEST_ROOT/long-activate.json" &
long_pid=$!
wait_for_file "$TEST_ROOT/act1.started" "the long activation did not start"
before=$(revision)
without=$(jq -c 'del(.routines[] | select(.id == "long-activate"))' <<<"$(renamed "Other during run")")
start=$(date +%s%3N)
result=$(printf '%s\n' "$without" | OMACHORD_LOCK_TIMEOUT=0.5 "$RUNNER" config apply "$before" || true)
elapsed=$(($(date +%s%3N) - start))
jq -e '.ok == false and .code == "routine-running" and .deactivated == []' <<<"$result" >/dev/null \
  || fail "orphaning a running activation did not return routine-running: $result"
((elapsed < 5000)) || fail "the routine-running apply took ${elapsed}ms"
assert_eq "$(revision)" "$before" "a routine-running apply changed the configuration"
[[ -f $STATE_DIR/active/long-activate.json ]] || fail "a routine-running apply ended the activation"
# An apply that keeps the routine proceeds while it is still activating.
apply_config "$(renamed "Other during activation")" | jq -e '.ok and .deactivated == []' >/dev/null \
  || fail "a compatible apply failed during an activation"
touch "$TEST_ROOT/act1.release"
wait "$long_pid" || fail "the long activation failed: $(cat "$TEST_ROOT/long-activate.json")"
jq -e '.ok and .state == "activated"' "$TEST_ROOT/long-activate.json" >/dev/null \
  || fail "the long activation did not complete"
[[ -f $TEST_ROOT/shell-state/dnd ]] || fail "the activation's setter was lost"
without=$(jq -c 'del(.routines[] | select(.id == "long-activate"))' <<<"$(renamed "Other during activation")")
apply_config "$without" | jq -e '.ok and .deactivated == ["long-activate"]' >/dev/null \
  || fail "the orphaned routine was not ended once it finished activating"
[[ ! -f $TEST_ROOT/shell-state/dnd ]] || fail "ending the orphan did not restore its setter"
[[ ! -e $STATE_DIR/active/long-activate.json ]] || fail "the orphan's record survived"
pass "routines release the config lock and serialize with writers by routine lock"

# --- Bulk cleanup: ordering, failure reporting and live-runner-bound hook suppression
apply_config "$(config_of \
  "$(routine ending '[]' '{"onEnd":{"mode":"actions","actions":[{"type":"theme","value":"ending-theme","restore":false},{"type":"exec","program":"detached-theme-set","args":[]}]}}')" \
  "$(routine on-theme '[{"type":"exec","program":"mark","args":["hooked"]}]' '{"triggers":[{"type":"hook","event":"theme-set"}]}')" \
  "$(routine keys '[]' '{"triggers":[{"type":"shortcut","keys":"SUPER + K","override":false}]}')")" \
  | jq -e '.ok' >/dev/null
"$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
: >"$TEST_ROOT/marks.log"
OMACHORD_BULK_CLEANUP=1 "$RUNNER" trigger hook theme-set x | jq -e '.matched == 1 and (.suppressed | not)' >/dev/null \
  || fail "an ambient bulk-cleanup flag suppressed hooks"
grep -Fqx hooked "$TEST_ROOT/marks.log" || fail "the hook routine did not run"
# Use a dedicated live owner: $BASHPID expanded inside a pipeline names a
# short-lived subshell, not this shell, so its start time would not match.
sleep 60 & owner_pid=$!
owner_start=$(awk '{print $22}' "/proc/$owner_pid/stat")
live_result=$(OMACHORD_BULK_CLEANUP="$owner_pid:$owner_start" "$RUNNER" trigger hook theme-set x)
kill "$owner_pid" 2>/dev/null || true
wait "$owner_pid" 2>/dev/null || true
jq -e '.suppressed == true' <<<"$live_result" >/dev/null \
  || fail "a live bulk-cleanup owner did not suppress hooks: $live_result"
# The same owner identity after that process has exited.
dead_result=$(OMACHORD_BULK_CLEANUP="$owner_pid:$owner_start" "$RUNNER" trigger hook theme-set x)
jq -e '.matched == 1 and (.suppressed | not)' <<<"$dead_result" >/dev/null \
  || fail "a finished runner still suppressed hooks: $dead_result"

"$RUNNER" activate ending manual | jq -e '.ok and .state == "activated"' >/dev/null
: >"$TEST_ROOT/theme-hook.log"
: >"$TEST_ROOT/marks.log"
# A failure before any side effect leaves the routine active.
printf '%s\n' 'SUPER + J → Existing binding' >"$TEST_ROOT/bindings.txt"
conflicting=$(jq -c 'del(.routines[] | select(.id == "ending")) | (.routines[] | select(.id == "keys") | .triggers[0].keys) = "SUPER + J"' "$CONFIG_PATH")
result=$(printf '%s\n' "$conflicting" | "$RUNNER" config apply "$(revision)" || true)
jq -e '.code == "shortcut-conflict" and (has("deactivated") | not)' <<<"$result" >/dev/null \
  || fail "a conflicting apply did not fail before ending routines: $result"
[[ -f $STATE_DIR/active/ending.json ]] || fail "a side-effect-free failure ended a routine"
: >"$TEST_ROOT/bindings.txt"
# A failure after the routine ended reports it in `deactivated`.
touch "$TEST_ROOT/error-after-reload"
rm -f "$TEST_ROOT/reloaded"
broken=$(jq -c 'del(.routines[] | select(.id == "ending")) | (.routines[] | select(.id == "keys") | .triggers[0].keys) = "SUPER + L"' "$CONFIG_PATH")
before=$(revision)
result=$(printf '%s\n' "$broken" | "$RUNNER" config apply "$before" || true)
rm -f "$TEST_ROOT/error-after-reload"
jq -e '.ok == false and (.code | test("rolled-back|rollback-failed")) and .deactivated == ["ending"]' <<<"$result" >/dev/null \
  || fail "a failure after ending routines omitted them: $result"
assert_eq "$(revision)" "$before" "the failed apply did not restore the configuration"
[[ ! -e $STATE_DIR/active/ending.json ]] || fail "the ended routine's record survived"
grep -Fq '"suppressed":true' "$TEST_ROOT/theme-hook.log" \
  || fail "the end action's hook was not suppressed during bulk cleanup: $(cat "$TEST_ROOT/theme-hook.log")"
[[ ! -s $TEST_ROOT/marks.log ]] || fail "a hook routine ran during bulk cleanup"
# The runner that set the marker has exited; its detached descendant's hook runs.
touch "$TEST_ROOT/detached.release"
wait_for_file "$TEST_ROOT/detached-hook.json" "the detached descendant did not trigger its hook"
jq -e '.matched == 1 and (.suppressed | not)' "$TEST_ROOT/detached-hook.json" >/dev/null \
  || fail "a detached descendant of a finished runner still suppressed hooks: $(cat "$TEST_ROOT/detached-hook.json")"
"$RUNNER" status | jq -e '.ok' >/dev/null
"$RUNNER" activate ending manual | jq -e '.ok and .state == "activated"' >/dev/null
touch "$TEST_ROOT/error-after-reload"
rm -f "$TEST_ROOT/reloaded"
result=$("$RUNNER" disconnect || true)
rm -f "$TEST_ROOT/error-after-reload" "$TEST_ROOT/reloaded"
jq -e '.ok == false and .deactivated == ["ending"]' <<<"$result" >/dev/null \
  || fail "a failed disconnect omitted the routines it ended: $result"
"$RUNNER" status | jq -e '.connected' >/dev/null || fail "the failed disconnect was not rolled back"
"$RUNNER" disconnect | jq -e '.ok' >/dev/null
pass "bulk cleanup ordering, failure reporting and hook suppression"

# --- Smaller hygiene regressions
"$RUNNER" help >"$TEST_ROOT/usage.txt"
for command in themes service-status theme-palette; do
  grep -Eq "^  $command( |$)" "$TEST_ROOT/usage.txt" || fail "usage does not list $command"
done

# `active` treats a record that vanished between listing and reading as
# inactive instead of failing the whole listing.
apply_config "$(config_of \
  "$(routine a-first '[{"type":"exec","program":"mark","args":["a"]}]' '{"keepUntil":{"minutes":5}}')" \
  "$(routine b-second '[{"type":"exec","program":"mark","args":["b"]}]' '{"keepUntil":{"minutes":5}}')" \
  "$(routine abort-me '[{"type":"exec","program":"hold","args":["abort"]}]')")" | jq -e '.ok' >/dev/null
"$RUNNER" activate a-first manual | jq -e '.ok and .state == "activated"' >/dev/null
"$RUNNER" activate b-second manual | jq -e '.ok and .state == "activated"' >/dev/null
cat >"$TEST_ROOT/vanish.bash" <<'EOF'
set -T
trap '[[ -n ${VANISH_PATH:-} && ${FUNCNAME[0]:-} == command_active && $BASH_COMMAND == "snapshot_state=0" ]] \
  && { rm -f -- "$VANISH_PATH"; VANISH_PATH=""; }' DEBUG
EOF
result=$(BASH_ENV="$TEST_ROOT/vanish.bash" VANISH_PATH="$STATE_DIR/active/a-first.json" "$RUNNER" active) \
  || fail "a vanished activation record failed the active listing: $result"
jq -e 'map(.routineId) == ["b-second"]' <<<"$result" >/dev/null \
  || fail "the active listing did not skip the vanished record: $result"
"$RUNNER" deactivate b-second manual | jq -e '.ok' >/dev/null

# A signal abort removes the runner's private temporary files.
mkdir -m 700 "$TEST_ROOT/abort-tmp"
TMPDIR="$TEST_ROOT/abort-tmp" "$RUNNER" run abort-me manual >/dev/null &
abort_pid=$!
wait_for_file "$TEST_ROOT/abort.started" "the abort routine did not start"
find "$TEST_ROOT/abort-tmp" -mindepth 1 -print -quit | grep -q . \
  || fail "the running routine had no private temporary files to clean up"
kill -TERM "$abort_pid"
if wait "$abort_pid"; then fail "the aborted routine reported success"; fi
leftover=$(find "$TEST_ROOT/abort-tmp" -mindepth 1 -print)
[[ -z $leftover ]] || fail "a signal abort left temporary files: $leftover"

# widget ensure/forget serialize on a dedicated lock.
"$RUNNER" widget forget | jq -e '.ok' >/dev/null
widget_lock="$XDG_RUNTIME_DIR/omachord/widget.lock"
[[ -f $widget_lock ]] || fail "widget forget did not use the widget lock"
flock -x "$widget_lock" sleep 3 &
holder=$!
for _ in {1..200}; do
  if ! flock -n "$widget_lock" true; then break; fi
  sleep 0.01
done
result=$(OMACHORD_LOCK_TIMEOUT=0.3 "$RUNNER" widget forget || true)
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
jq -e '.ok == false and .error == "Timed out locking the bar widget state"' <<<"$result" >/dev/null \
  || fail "widget forget did not wait for a concurrent widget operation: $result"
pass "usage, active-listing race, abort cleanup and widget lock"

printf 'Runner lifecycle tests passed.\n'
