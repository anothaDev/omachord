#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/bin/omachord"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-speed-test.XXXXXX")
export TEST_ROOT

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_eq() {
  [[ $1 == "$2" ]] || fail "${3:-expected '$2', got '$1'}"
}

assert_missing() {
  [[ ! -e $1 ]] || fail "${2:-$1 should not exist}"
}

wait_for_path() {
  local path=$1
  for _ in {1..500}; do
    [[ -e $path ]] && return 0
    sleep 0.01
  done
  fail "$path did not appear before the timeout"
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/state" "$TEST_ROOT/data"
: >"$TEST_ROOT/bindings.txt"

cat >"$TEST_ROOT/bin/omarchy" <<'STUB'
#!/bin/bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "menu keybindings --print")
    if [[ -e $TEST_ROOT/trace-keybindings ]]; then
      printf '%s\n' keybindings >>"$TEST_ROOT/keybindings.calls"
    fi
    cat "$TEST_ROOT/bindings.txt"
    ;;
  "audio input mute")
    if [[ -e $TEST_ROOT/mic-muted ]]; then
      rm -f -- "$TEST_ROOT/mic-muted"
    else
      touch "$TEST_ROOT/mic-muted"
    fi
    ;;
  *) exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/hyprctl" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ -e $TEST_ROOT/trace-hypr ]]; then
  printf '%s\n' "${1:-}" >>"$TEST_ROOT/hypr.calls"
fi
case ${1:-} in
  configerrors)
    [[ ! -e $TEST_ROOT/baseline-error ]] || printf '%s\n' 'existing configuration error'
    ;;
  reload)
    count=$(cat "$TEST_ROOT/reload.count" 2>/dev/null || printf 0)
    printf '%s\n' "$((count + 1))" >"$TEST_ROOT/reload.count"
    ;;
  *) exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/wpctl" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ -e $TEST_ROOT/mic-muted ]]; then
  printf '%s\n' 'Volume: 1.00 [MUTED]'
else
  printf '%s\n' 'Volume: 1.00'
fi
STUB

cat >"$TEST_ROOT/bin/paplay" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ -e $TEST_ROOT/delay-paplay ]]; then
  : >"$TEST_ROOT/paplay.fds"
  for fd in 6 7 8 9; do
    [[ ! -e /proc/$$/fd/$fd ]] || printf '%s\n' "$fd" >>"$TEST_ROOT/paplay.fds"
  done
  touch "$TEST_ROOT/paplay.started"
  sleep 4
  touch "$TEST_ROOT/paplay.finished"
fi
printf '%s\n' "$1" >>"$TEST_ROOT/sounds.log"
STUB

chmod +x "$TEST_ROOT/bin"/*

export HOME="$TEST_ROOT/home"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin"

OMARCHY_CONFIG_DIR="$HOME/.config/omarchy"
CONFIG_PATH="$OMARCHY_CONFIG_DIR/omachord.json"
HYPR_DIR="$HOME/.config/hypr"
STATE_DIR="$XDG_STATE_HOME/omarchy/omachord"
PLUGIN_DIR="$OMARCHY_CONFIG_DIR/plugins/anothadev.omachord"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$HYPR_DIR" "$(dirname "$PLUGIN_DIR")"
ln -s "$ROOT" "$PLUGIN_DIR"

muted_sound="$TEST_ROOT/muted.oga"
live_sound="$TEST_ROOT/live.oga"
: >"$muted_sound"
: >"$live_sound"

CONFIG=$(jq -cn --arg muted "$muted_sound" --arg live "$live_sound" '{
  version: 1,
  routines: [
    {
      id: "shortcut",
      name: "Shortcut routine",
      enabled: true,
      triggers: [{type:"shortcut",keys:"SUPER + M",override:false}],
      actions: [{type:"delay",milliseconds:0}]
    },
    {
      id: "microphone",
      name: "Microphone",
      enabled: true,
      triggers: [],
      actions: [{
        type:"microphone-toggle",
        sound:true,
        mutedSound:$muted,
        liveSound:$live
      }]
    }
  ]
}')

config_revision() {
  "$RUNNER" config snapshot | jq -er '.revision'
}

apply_config() {
  local payload=$1 revision=${2:-}
  [[ -n $revision ]] || revision=$(config_revision)
  printf '%s\n' "$payload" | "$RUNNER" config apply "$revision"
}

apply_config "$CONFIG" >/dev/null
"$RUNNER" connect >/dev/null

# Parsing hundreds of rows must have a constant jq process count and little
# row-count-dependent runtime. The first row also verifies exact managed
# attribution survived batching.
counter_bin="$TEST_ROOT/jq-counter-bin"
mkdir -p "$counter_bin"
cat >"$counter_bin/jq" <<'STUB'
#!/bin/bash
count=$(/usr/bin/cat "$OMACHORD_JQ_COUNT_FILE" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" >"$OMACHORD_JQ_COUNT_FILE"
exec /usr/bin/jq "$@"
STUB
chmod +x "$counter_bin/jq"
printf '%s\n' 'SUPER + M -> Omachord: Shortcut routine' >"$TEST_ROOT/bindings.txt"
single_started=$(date +%s%3N)
"$RUNNER" bindings >/dev/null
single_elapsed=$(($(date +%s%3N) - single_started))
for index in {1..249}; do
  printf 'SUPER + KEY%03d → External binding %03d\n' "$index" "$index" >>"$TEST_ROOT/bindings.txt"
done
bindings_started=$(date +%s%3N)
OMACHORD_JQ_COUNT_FILE="$TEST_ROOT/jq.count" PATH="$counter_bin:$PATH" \
  "$RUNNER" bindings >"$TEST_ROOT/bindings.json"
bindings_elapsed=$(($(date +%s%3N) - bindings_started))
row_overhead=$((bindings_elapsed - single_elapsed))
jq_count=$(cat "$TEST_ROOT/jq.count")
/usr/bin/jq -e '
  length == 250
  and any(.[]; .keys == "SUPER + M"
    and .description == "Omachord: Shortcut routine"
    and .managed and .editable)
' "$TEST_ROOT/bindings.json" >/dev/null \
  || fail "batched keybinding output lost rows or managed metadata"
((jq_count <= 4)) || fail "250 binding rows spawned $jq_count jq processes"
((row_overhead < 400)) \
  || fail "249 extra binding rows added ${row_overhead}ms of parser overhead"

cat >"$TEST_ROOT/bindings.txt" <<'ROWS'
ctrl super shift + comma -> Punctuation alias
WIN CONTROL ALT + slash → Modifier aliases
SUPER + LEFT MOUSE BUTTON -> Pointer binding
é -> Unicode key
 -> Empty key
ROWS
"$RUNNER" bindings >"$TEST_ROOT/normalized-bindings.json"
/usr/bin/jq -e '
  any(.[]; .description == "Punctuation alias"
    and .keys == "SUPER + SHIFT + CTRL + comma" and .editable)
  and any(.[]; .description == "Modifier aliases"
    and .keys == "SUPER + CTRL + ALT + slash" and .editable)
  and any(.[]; .description == "Pointer binding"
    and .keys == "SUPER + LEFT MOUSE BUTTON" and (.editable | not))
  and any(.[]; .description == "Unicode key" and .keys == "É" and .editable)
  and any(.[]; .description == "Empty key" and .keys == "" and (.editable | not))
' "$TEST_ROOT/normalized-bindings.json" >/dev/null \
  || fail "batched keybinding normalization changed established semantics"
printf '%s\n' 'unrecognized binding row' >"$TEST_ROOT/bindings.txt"
if "$RUNNER" bindings >/dev/null; then
  fail "batched keybinding parser accepted an unrecognized row"
fi
: >"$TEST_ROOT/bindings.txt"
printf 'BENCH bindings rows=250 jq_processes=%s single_ms=%s elapsed_ms=%s row_overhead_ms=%s\n' \
  "$jq_count" "$single_elapsed" "$bindings_elapsed" "$row_overhead"

# An action-only edit has identical generated Lua. It must not consult the
# shortcut catalogue or Hyprland, and must not replace the generated file.
FAST_CONFIG=$(jq -c '(.routines[] | select(.id == "microphone") | .actions[0].sound) = false' \
  <<<"$CONFIG")
generated_before=$(stat -c '%d:%i:%s:%a' "$HYPR_DIR/omachord.lua")
printf '%s\n' 'the fast path must not parse this row' >"$TEST_ROOT/bindings.txt"
touch "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr" "$TEST_ROOT/baseline-error"
fast_started=$(date +%s%3N)
apply_config "$FAST_CONFIG" >"$TEST_ROOT/fast.result"
fast_elapsed=$(($(date +%s%3N) - fast_started))
jq -e '.ok and .connected and .warnings == []' "$TEST_ROOT/fast.result" >/dev/null \
  || fail "action-only config apply failed"
assert_missing "$TEST_ROOT/keybindings.calls" "fast config apply queried keybindings"
assert_missing "$TEST_ROOT/hypr.calls" "fast config apply queried or reloaded Hyprland"
assert_eq "$(stat -c '%d:%i:%s:%a' "$HYPR_DIR/omachord.lua")" "$generated_before" \
  "fast config apply replaced unchanged generated Lua"
rm -f -- "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr" "$TEST_ROOT/baseline-error"
: >"$TEST_ROOT/bindings.txt"

# If generated Lua changes after the fast-path decision, the config CAS is
# rolled back and the external edit is deliberately left untouched.
cp -- "$HYPR_DIR/omachord.lua" "$TEST_ROOT/generated.expected"
race_revision=$(config_revision)
printf '%s\n' "$CONFIG" \
  | env OMACHORD_FS_TEST_MATCH="$CONFIG_PATH" OMACHORD_FS_TEST_PAUSE=before-publish \
      OMACHORD_FS_TEST_READY="$TEST_ROOT/race.ready" \
      OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/race.release" \
      "$RUNNER" config apply "$race_revision" >"$TEST_ROOT/race.result" &
race_pid=$!
wait_for_path "$TEST_ROOT/race.ready"
printf '%s\n' 'external generated Lua edit' >"$HYPR_DIR/omachord.lua"
touch "$TEST_ROOT/race.release"
if wait "$race_pid"; then
  fail "fast config apply accepted a concurrent generated-Lua edit"
fi
jq -e '.code == "write-rolled-back"' "$TEST_ROOT/race.result" >/dev/null \
  || fail "generated-Lua race returned the wrong rollback code"
assert_eq "$(cat "$HYPR_DIR/omachord.lua")" 'external generated Lua edit' \
  "fast-path rollback overwrote an external generated-Lua edit"
jq -e '(.routines[] | select(.id == "microphone") | .actions[0].sound) == false' \
  "$CONFIG_PATH" >/dev/null || fail "generated-Lua race did not restore the old config"

# Wrong permissions force the full repair path even though shortcut content
# is unchanged. This must restore mode 0600 and perform the catalogue/reload.
cp -- "$TEST_ROOT/generated.expected" "$HYPR_DIR/omachord.lua"
chmod 666 "$HYPR_DIR/omachord.lua"
rm -f -- "$TEST_ROOT/keybindings.calls" "$TEST_ROOT/hypr.calls" "$TEST_ROOT/reload.count"
touch "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
fallback_started=$(date +%s%3N)
apply_config "$CONFIG" >"$TEST_ROOT/fallback.result"
fallback_elapsed=$(($(date +%s%3N) - fallback_started))
jq -e '.ok and .connected' "$TEST_ROOT/fallback.result" >/dev/null \
  || fail "generated-Lua repair apply failed"
cmp -s -- "$TEST_ROOT/generated.expected" "$HYPR_DIR/omachord.lua" \
  || fail "generated-Lua repair wrote the wrong content"
assert_eq "$(stat -c %a "$HYPR_DIR/omachord.lua")" 600 \
  "generated-Lua repair left unsafe permissions"
assert_eq "$(cat "$TEST_ROOT/reload.count")" 1 \
  "generated-Lua repair did not reload exactly once"
[[ $(wc -l <"$TEST_ROOT/keybindings.calls") -ge 2 ]] \
  || fail "generated-Lua repair skipped catalogue or shadow checks"
grep -Fxq reload "$TEST_ROOT/hypr.calls" \
  || fail "generated-Lua repair skipped the Hyprland reload"
rm -f -- "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
printf 'BENCH config_apply fast_ms=%s repair_ms=%s\n' "$fast_elapsed" "$fallback_elapsed"

# Candidate-looking generated bytes must not fool the fast path when the
# currently committed configuration has a different shortcut projection. The
# file may have been edited without a Hyprland reload, so apply must reload it.
PREEDIT_CONFIG=$(jq -c '
  (.routines[] | select(.id == "shortcut") | .triggers[0].keys) = "SUPER + N"
' <<<"$CONFIG")
sed 's/SUPER + M/SUPER + N/' "$TEST_ROOT/generated.expected" >"$HYPR_DIR/omachord.lua"
chmod 600 "$HYPR_DIR/omachord.lua"
rm -f -- "$TEST_ROOT/keybindings.calls" "$TEST_ROOT/hypr.calls" "$TEST_ROOT/reload.count"
touch "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
apply_config "$PREEDIT_CONFIG" >"$TEST_ROOT/preedited.result"
jq -e '.ok and .connected' "$TEST_ROOT/preedited.result" >/dev/null \
  || fail "pre-edited generated-Lua repair failed"
assert_eq "$(cat "$TEST_ROOT/reload.count")" 1 \
  "candidate-looking generated Lua skipped its required reload"
[[ $(wc -l <"$TEST_ROOT/keybindings.calls") -ge 2 ]] \
  || fail "candidate-looking generated Lua skipped full conflict checks"

# Restore the baseline shortcut, then invalidate only its commit marker. Even
# though current/candidate/on-disk shortcuts all match, an interrupted prior
# transaction is not proof that Hyprland loaded them and must take full repair.
rm -f -- "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
: >"$TEST_ROOT/bindings.txt"
apply_config "$CONFIG" >/dev/null
uncommitted_revision="sha256:$(sha256sum -- "$CONFIG_PATH" | awk '{print $1}')"
jq -cn --arg revision "sha256:$(printf stale | sha256sum | awk '{print $1}')" \
  '{version:1,revision:$revision}' >"$STATE_DIR/config.commit.json"
chmod 600 "$STATE_DIR/config.commit.json"
rm -f -- "$TEST_ROOT/keybindings.calls" "$TEST_ROOT/hypr.calls" "$TEST_ROOT/reload.count"
touch "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
apply_config "$FAST_CONFIG" "$uncommitted_revision" >"$TEST_ROOT/uncommitted-fast.result"
jq -e '.ok and .connected' "$TEST_ROOT/uncommitted-fast.result" >/dev/null \
  || fail "uncommitted generated-Lua repair failed"
assert_eq "$(cat "$TEST_ROOT/reload.count")" 1 \
  "uncommitted configuration incorrectly used the reload-free path"
[[ $(wc -l <"$TEST_ROOT/keybindings.calls") -ge 2 ]] \
  || fail "uncommitted configuration skipped full conflict checks"
rm -f -- "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"

# Missing cue files still fail synchronously even though valid playback is
# detached. Both paths are made missing so the starting mute state is moot.
missing_sound="$TEST_ROOT/missing.oga"
MISSING_CONFIG=$(jq -c --arg path "$missing_sound" '
  (.routines[] | select(.id == "microphone") | .actions[0])
    |= (.mutedSound = $path | .liveSound = $path)
' <<<"$CONFIG")
apply_config "$MISSING_CONFIG" >/dev/null
if "$RUNNER" run microphone test >"$TEST_ROOT/missing.result"; then
  fail "microphone action accepted a missing cue file"
fi
jq -e --arg path "$missing_sound" '
  .code == "action-failed" and .error == ("Sound file not found: " + $path)
' "$TEST_ROOT/missing.result" >/dev/null \
  || fail "missing microphone cue returned the wrong error"
apply_config "$CONFIG" >/dev/null

# A four-second player must outlive the routine, while descriptors 6-9 and
# their corresponding microphone/routine/configuration locks are released.
rm -f -- "$TEST_ROOT/paplay.started" "$TEST_ROOT/paplay.finished" \
  "$TEST_ROOT/paplay.fds" "$TEST_ROOT/sounds.log"
touch "$TEST_ROOT/delay-paplay"
mic_started=$(date +%s%3N)
"$RUNNER" run microphone test >"$TEST_ROOT/microphone.result"
mic_elapsed=$(($(date +%s%3N) - mic_started))
jq -e '.ok' "$TEST_ROOT/microphone.result" >/dev/null \
  || fail "microphone action failed before detached playback"
((mic_elapsed < 3000)) || fail "microphone action waited ${mic_elapsed}ms for playback"
wait_for_path "$TEST_ROOT/paplay.started"
assert_missing "$TEST_ROOT/paplay.finished" "microphone action waited for cue completion"
[[ ! -s $TEST_ROOT/paplay.fds ]] \
  || fail "paplay inherited runner descriptors: $(tr '\n' ' ' <"$TEST_ROOT/paplay.fds")"
for lock_path in \
  "$XDG_RUNTIME_DIR/omachord/resource-microphone.lock" \
  "$XDG_RUNTIME_DIR/omachord/routine-microphone.lock" \
  "$STATE_DIR/config.lock"; do
  flock -n "$lock_path" true \
    || fail "paplay retained $(basename "$lock_path")"
done
wait_for_path "$TEST_ROOT/paplay.finished"
grep -Fxq "$live_sound" "$TEST_ROOT/sounds.log" \
  || fail "detached microphone cue used the wrong sound"
printf 'BENCH microphone return_ms=%s playback_ms=4000\n' "$mic_elapsed"

printf 'Runner speed tests passed.\n'
