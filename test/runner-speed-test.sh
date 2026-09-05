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
    [[ ! -e $TEST_ROOT/catalogue-unavailable ]] || exit 1
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
    if [[ -e $TEST_ROOT/bindings-after-reload.txt ]]; then
      cp -- "$TEST_ROOT/bindings-after-reload.txt" "$TEST_ROOT/bindings.txt"
    fi
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
printf '%s\n' jq >>"$OMACHORD_JQ_COUNT_FILE"
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
jq_count=$(wc -l <"$TEST_ROOT/jq.count")
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

# Global Connect and its following status refresh must not spawn jq once per
# shortcut. Count real jq executions around public commands, not test setup;
# elapsed times are diagnostics only, since filesystem durability is unchanged.
measure_global() {
  local label=$1 command=$2 started
  : >"$TEST_ROOT/global-jq.calls"
  : >"$TEST_ROOT/keybindings.calls"
  : >"$TEST_ROOT/hypr.calls"
  touch "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
  started=$(date +%s%3N)
  OMACHORD_JQ_COUNT_FILE="$TEST_ROOT/global-jq.calls" PATH="$counter_bin:$PATH" \
    "$RUNNER" "$command" >"$TEST_ROOT/$label-$command.json"
  MEASURE_ELAPSED=$(($(date +%s%3N) - started))
  MEASURE_JQ_COUNT=$(wc -l <"$TEST_ROOT/global-jq.calls")
  MEASURE_CATALOGUE_COUNT=$(wc -l <"$TEST_ROOT/keybindings.calls")
  rm -f -- "$TEST_ROOT/trace-keybindings" "$TEST_ROOT/trace-hypr"
  printf 'BENCH global %s command=%s jq_processes=%s catalogue_queries=%s elapsed_ms=%s\n' \
    "$label" "$command" "$MEASURE_JQ_COUNT" "$MEASURE_CATALOGUE_COUNT" "$MEASURE_ELAPSED"
}

for shortcut_count in 1 64; do
  "$RUNNER" disconnect >/dev/null
  MANY_CONFIG=$(jq -cn --argjson count "$shortcut_count" '{version:1,routines:[
    range(1; $count + 1) | tostring as $index | {
      id:("shortcut-" + $index), name:("Shortcut " + $index), enabled:true,
      triggers:[{type:"shortcut",keys:("SUPER + KEY" + $index),override:false}],
      actions:[{type:"delay",milliseconds:0}]
    }
  ]}')
  apply_config "$MANY_CONFIG" >/dev/null
  measure_global "shortcuts=$shortcut_count" connect
  connect_jq_count=$MEASURE_JQ_COUNT
  assert_eq "$MEASURE_CATALOGUE_COUNT" 2 "Connect must check fresh bindings again after reload"
  assert_eq "$(grep -c '^reload$' "$TEST_ROOT/hypr.calls")" 1 "Connect must reload exactly once"
  jq -e --argjson count "$shortcut_count" '
    .ok and .connected and (.repaired | not)
    and (.revision | test("^sha256:[0-9a-f]{64}$"))
    and .warnings == [range(1; $count + 1) | tostring as $index
      | "SUPER + KEY\($index) did not resolve to Omachord: Shortcut \($index) after reload"]
  ' "$TEST_ROOT/shortcuts=$shortcut_count-connect.json" >/dev/null \
    || fail "Connect lost ordered shadow warnings or its success contract"
  assert_eq "$(stat -c %a "$HYPR_DIR/omachord.lua")" 600 "Connect changed generated Lua permissions"
  config_before=$(sha256sum -- "$CONFIG_PATH")
  generated_before=$(stat -c '%d:%i:%s:%a' "$HYPR_DIR/omachord.lua")
  measure_global "shortcuts=$shortcut_count" status
  jq -e '.ok and .connected and .configValid and .integrationComplete and .hyprlandClean' \
    "$TEST_ROOT/shortcuts=$shortcut_count-status.json" >/dev/null \
    || fail "global status lost integration validation"
  assert_eq "$MEASURE_CATALOGUE_COUNT" 0 "status queried the shortcut catalogue"
  assert_eq "$(sha256sum -- "$CONFIG_PATH")" "$config_before" "status changed the configuration"
  assert_eq "$(stat -c '%d:%i:%s:%a' "$HYPR_DIR/omachord.lua")" "$generated_before" \
    "status replaced generated Lua"
  if ((shortcut_count == 1)); then
    single_connect_jq_count=$connect_jq_count
    single_status_jq_count=$MEASURE_JQ_COUNT
  else
    ((connect_jq_count <= single_connect_jq_count)) \
      || fail "63 extra shortcuts added $((connect_jq_count - single_connect_jq_count)) jq processes to Connect"
    ((MEASURE_JQ_COUNT <= single_status_jq_count)) \
      || fail "63 extra shortcuts added $((MEASURE_JQ_COUNT - single_status_jq_count)) jq processes to status"
  fi
done

# Literal field transport must retain Bash's exact Lua bytes, including tabs,
# surrounding whitespace, quotes and backslashes (JSON quoting is not Lua
# quoting). Disabled and hook-only routines must not produce bindings.
QUOTED_CONFIG=$(jq -cn --arg name $' \t"Quoted" \\ $(touch should-not-run)  ' '{version:1,routines:[
  {id:"quoted",name:$name,enabled:true,
   triggers:[{type:"shortcut",keys:"SUPER + Q",override:true}],actions:[]},
  {id:"punctuation",name:"Punctuation",enabled:true,
   triggers:[{type:"shortcut",keys:"SUPER + \"\\",override:false}],actions:[]},
  {id:"disabled",name:"Disabled",enabled:false,
   triggers:[{type:"shortcut",keys:"SUPER + D",override:true}],actions:[]},
  {id:"hook",name:"Hook",enabled:true,
   triggers:[{type:"hook",event:"post-boot"}],actions:[]}
]}')
apply_config "$QUOTED_CONFIG" >/dev/null
{
  printf '%s\n' '-- Generated by Omachord. Do not edit.'
  printf 'local runner = "%s/bin/omachord"\n' "$PLUGIN_DIR"
  cat <<'LUA'
if o.cmd_present(runner) then
  hl.unbind("SUPER + Q")
  o.bind("SUPER + Q", "Omachord:  	\"Quoted\" \\ $(touch should-not-run)  ", o.shell_quote(runner) .. " run " .. o.shell_quote("quoted") .. " shortcut")
  o.bind("SUPER + \"\\", "Omachord: Punctuation", o.shell_quote(runner) .. " run " .. o.shell_quote("punctuation") .. " shortcut")
end
LUA
} >"$TEST_ROOT/quoted.expected.lua"
cmp -s -- "$TEST_ROOT/quoted.expected.lua" "$HYPR_DIR/omachord.lua" \
  || fail "batched shortcut extraction changed literal Lua bytes"

# Conflict order is routine order first, then the catalogue's sorted order,
# not input row order. A brand-like prefix alone must never confer ownership.
MATCH_CONFIG='{"version":1,"routines":[
  {"id":"first","name":"First","enabled":true,"triggers":[{"type":"shortcut","keys":"SUPER + B","override":false}],"actions":[]},
  {"id":"second","name":"Second","enabled":true,"triggers":[{"type":"shortcut","keys":"SUPER + A","override":false}],"actions":[]}
]}'
cat >"$TEST_ROOT/bindings.txt" <<'ROWS'
SUPER + B -> Zulu first-key conflict
SUPER + A -> Aardvark second-key conflict
SUPER + B -> Alpha first-key conflict
ROWS
config_before=$(sha256sum -- "$CONFIG_PATH")
if apply_config "$MATCH_CONFIG" >"$TEST_ROOT/first-conflict.json"; then
  fail "Connect preflight accepted conflicting shortcuts"
fi
jq -e '. == {ok:false,code:"shortcut-conflict",error:"SUPER + B is already assigned to Alpha first-key conflict"}' \
  "$TEST_ROOT/first-conflict.json" >/dev/null || fail "first-conflict selection changed"
assert_eq "$(sha256sum -- "$CONFIG_PATH")" "$config_before" "conflict check changed the configuration"
OVERRIDE_CONFIG=$(jq -c '.routines[0].triggers[0].override = true' <<<"$MATCH_CONFIG")
printf '%s\n' 'SUPER + A -> Omachord: Personal binding' >>"$TEST_ROOT/bindings.txt"
if apply_config "$OVERRIDE_CONFIG" >"$TEST_ROOT/override-conflict.json"; then
  fail "overriding one shortcut suppressed another shortcut conflict"
fi
jq -e '.error == "SUPER + A is already assigned to Aardvark second-key conflict"' \
  "$TEST_ROOT/override-conflict.json" >/dev/null || fail "override skipped the wrong conflict"
printf '%s\n' 'SUPER + A -> Omachord: Personal binding' >"$TEST_ROOT/bindings.txt"
if apply_config "$OVERRIDE_CONFIG" >"$TEST_ROOT/prefix-conflict.json"; then
  fail "brand-like description was incorrectly attributed to Omachord"
fi
jq -e '.error == "SUPER + A is already assigned to Omachord: Personal binding"' \
  "$TEST_ROOT/prefix-conflict.json" >/dev/null || fail "brand-like prefix conflict changed"

# Preserve the historical empty-first-description behavior. After the reload,
# replace these external rows with a legacy managed description and a shadow:
# the warning must be based on this NEW catalogue, never the preflight result.
printf '%s\n' 'SUPER + B -> ' 'SUPER + B -> Zulu ignored after empty description' \
  'SUPER + A -> ' >"$TEST_ROOT/bindings.txt"
cat >"$TEST_ROOT/bindings-after-reload.txt" <<'ROWS'
SUPER + B -> Oma: First
SUPER + A -> External shadow
ROWS
apply_config "$MATCH_CONFIG" >"$TEST_ROOT/fresh-warnings.json"
jq -e '.ok and .warnings == ["SUPER + A did not resolve to Omachord: Second after reload"]' \
  "$TEST_ROOT/fresh-warnings.json" >/dev/null || fail "warnings reused stale bindings or lost legacy attribution"
"$RUNNER" bindings | jq -e 'any(.[]; .keys == "SUPER + B" and .managed and .description == "Omachord: First")' \
  >/dev/null || fail "legacy managed binding lost exact attribution"
rm -f -- "$TEST_ROOT/bindings-after-reload.txt"
LEGACY_CONFIG=$(jq -c '.routines[1].enabled = false' <<<"$MATCH_CONFIG")
apply_config "$LEGACY_CONFIG" | jq -e '.ok and .warnings == []' >/dev/null \
  || fail "legacy managed binding caused a false conflict"
: >"$TEST_ROOT/bindings.txt"

# Neither an empty document, disabled shortcuts, nor enabled hook-only routines
# need the shortcut catalogue. Hyprland validation/reload and integration writes
# must still happen, including when globally disabling the integration again.
for zero_case in empty disabled hook-only; do
  "$RUNNER" disconnect >/dev/null
  case $zero_case in
    empty) ZERO_CONFIG='{"version":1,"routines":[]}' ;;
    disabled) ZERO_CONFIG=$(jq -c '.routines[].enabled = false' <<<"$CONFIG") ;;
    hook-only) ZERO_CONFIG=$(jq -c '.routines[].triggers = [{type:"hook",event:"post-boot"}]' <<<"$CONFIG") ;;
  esac
  apply_config "$ZERO_CONFIG" >/dev/null
  measure_global "$zero_case" connect
  zero_catalogue_count=$MEASURE_CATALOGUE_COUNT
  jq -e '.ok and .connected and .warnings == []' "$TEST_ROOT/$zero_case-connect.json" >/dev/null \
    || fail "Connect without enabled shortcuts failed"
  assert_eq "$(grep -c '^reload$' "$TEST_ROOT/hypr.calls")" 1 "empty-shortcut Connect skipped reload"
  measure_global "$zero_case" status
  jq -e '.ok and .connected and .configValid and .integrationComplete and .hyprlandClean' \
    "$TEST_ROOT/$zero_case-status.json" >/dev/null \
    || fail "empty-shortcut status skipped integration validation"
  assert_eq "$MEASURE_CATALOGUE_COUNT" 0 "empty-shortcut status queried the catalogue"
  measure_global "$zero_case" disconnect
  jq -e '. == {ok:true,connected:false,deactivated:[]}' "$TEST_ROOT/$zero_case-disconnect.json" >/dev/null \
    || fail "Disconnect changed its success contract"
  assert_eq "$(grep -c '^reload$' "$TEST_ROOT/hypr.calls")" 1 "Disconnect skipped reload"
  assert_eq "$MEASURE_CATALOGUE_COUNT" 0 "Disconnect queried the catalogue"
  assert_eq "$zero_catalogue_count" 0 "$zero_case Connect queried the catalogue $zero_catalogue_count times"
done

# Unavailable catalogue data is irrelevant without enabled shortcuts, but must
# still fail closed for a nonempty candidate. Do not weaken Hyprland checks.
touch "$TEST_ROOT/catalogue-unavailable"
apply_config "$ZERO_CONFIG" >/dev/null
"$RUNNER" connect | jq -e '.ok and .warnings == []' >/dev/null \
  || fail "hook-only Connect depended on the unavailable shortcut catalogue"
if apply_config "$CONFIG" >"$TEST_ROOT/unavailable-catalogue.json"; then
  fail "nonempty shortcuts ignored an unavailable catalogue"
fi
jq -e '.code == "shortcut-conflict" and .error == "Could not read effective Omarchy keybindings"' \
  "$TEST_ROOT/unavailable-catalogue.json" >/dev/null || fail "catalogue failure changed its error contract"
rm -f -- "$TEST_ROOT/catalogue-unavailable"
apply_config "$CONFIG" >/dev/null
"$RUNNER" connect >/dev/null
rm -f -- "$TEST_ROOT/keybindings.calls" "$TEST_ROOT/hypr.calls"

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
