#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/bin/omachord"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-test.XXXXXX")
export TEST_ROOT
cd "$ROOT"

cleanup() {
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

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "${3:-$1 does not contain $2}"
}

wait_for_file_contains() {
  local file=$1 needle=$2
  for _ in {1..500}; do
    if [[ -f $file ]] && grep -Fq -- "$needle" "$file"; then return 0; fi
    sleep 0.01
  done
  fail "${file} did not contain ${needle} before the timeout"
}

assert_missing() {
  [[ ! -e $1 ]] || fail "${2:-$1 should not exist}"
}

action_supervisor_for() {
  pgrep -P "$1" -f 'omachord-action-supervisor' 2>/dev/null | head -n 1
}

action_timeout_for() {
  local supervisor
  supervisor=$(action_supervisor_for "$1") || return 1
  pgrep -P "$supervisor" -x timeout 2>/dev/null | head -n 1
}

mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/config/hypr" "$TEST_ROOT/state" "$TEST_ROOT/data"
: >"$TEST_ROOT/bindings.txt"
: >"$TEST_ROOT/command.log"

cat >"$TEST_ROOT/bin/omarchy" <<'STUB'
#!/bin/bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "menu keybindings --print")
    cat "$TEST_ROOT/bindings.txt"
    if [[ -f $TEST_ROOT/inject-connect-config-race ]]; then
      cp -- "$TEST_ROOT/concurrent-config.json" "$HOME/.config/omarchy/omachord.json"
      chmod 600 "$HOME/.config/omarchy/omachord.json"
      rm -f "$TEST_ROOT/inject-connect-config-race"
    fi
    if [[ -f $TEST_ROOT/inject-connect-large-config-race ]]; then
      truncate -s 1073741824 "$HOME/.config/omarchy/omachord.json"
      chmod 600 "$HOME/.config/omarchy/omachord.json"
      rm -f "$TEST_ROOT/inject-connect-large-config-race"
    fi
    ;;
  "commands --json ")
    printf '%s\n' '{"commands":[{"route":"omarchy safe echo","routes":["omarchy safe echo","omarchy echo"],"binary":"omarchy-safe-echo","summary":"Test command","requires_sudo":false,"hidden":false,"args":"[values...]"},{"route":"omarchy unsafe","routes":["omarchy unsafe"],"binary":"omarchy-unsafe","summary":"Privileged test","requires_sudo":true,"hidden":false,"args":""}]}'
    if [[ -f $TEST_ROOT/control-output-child ]]; then
      rm -f "$TEST_ROOT/control-output-child"
      (sleep 5) &
    fi
    if [[ -f $TEST_ROOT/control-output-overflow ]]; then
      rm -f "$TEST_ROOT/control-output-overflow"
      (
        printf '%s\n' "$BASHPID" >"$TEST_ROOT/control-overflow.pid"
        trap '' TERM
        { head -c 1048577 /dev/zero | tr '\0' x; } || true
        sleep 5
        touch "$TEST_ROOT/control-overflow-survived"
      ) &
    fi
    ;;
  "audio input mute")
    if [[ -f $TEST_ROOT/mic-muted ]]; then rm -f "$TEST_ROOT/mic-muted"; else touch "$TEST_ROOT/mic-muted"; fi
    ;;
  *) printf 'omarchy' >>"$TEST_ROOT/command.log"; printf ' <%s>' "$@" >>"$TEST_ROOT/command.log"; printf '\n' >>"$TEST_ROOT/command.log" ;;
esac
STUB

cat >"$TEST_ROOT/bin/hyprctl" <<'STUB'
#!/bin/bash
set -euo pipefail
case ${1:-} in
  configerrors)
    if [[ -f $TEST_ROOT/create-connect-collision ]]; then
      printf '%s\n' 'concurrently created' >"$HOME/.config/hypr/omachord.lua"
      rm -f "$TEST_ROOT/create-connect-collision"
    fi
    if [[ -f $TEST_ROOT/create-loader-collision ]]; then
      printf '%s\n' 'require("default.hypr.require_optional").module("hypr.omachord") -- Oma Chord managed loader' \
        >>"$HOME/.config/hypr/bindings.lua"
      rm -f "$TEST_ROOT/create-loader-collision"
    fi
    reload_count=$(cat "$TEST_ROOT/reload-count" 2>/dev/null || printf 0)
    if [[ -f $HOME/.config/hypr/omachord.lua ]] \
      && grep -Fq 'BROKEN OMA LUA' "$HOME/.config/hypr/omachord.lua"; then
      printf '%s\n' 'omachord.lua: generated syntax error'
    elif [[ -f $TEST_ROOT/always-error-after-reload && $reload_count -gt 0 ]]; then
      printf '%s\n' 'persistent generated configuration error'
    elif [[ -f $TEST_ROOT/error-after-reload && $reload_count -eq 1 ]]; then
      printf '%s\n' 'generated configuration error'
    elif [[ -f $TEST_ROOT/baseline-error ]]; then
      printf '%s\n' 'existing configuration error'
    fi
    ;;
  reload)
    reload_count=$(cat "$TEST_ROOT/reload-count" 2>/dev/null || printf 0)
    printf '%s\n' "$((reload_count + 1))" >"$TEST_ROOT/reload-count"
    touch "$TEST_ROOT/reloaded"
    printf '%s\n' reload >>"$TEST_ROOT/hypr.log"
    ;;
  *) exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/wpctl" <<'STUB'
#!/bin/bash
if [[ -f $TEST_ROOT/mic-muted ]]; then
  printf '%s\n' 'Volume: 1.00 [MUTED]'
else
  printf '%s\n' 'Volume: 1.00'
fi
STUB

cat >"$TEST_ROOT/bin/paplay" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >>"$TEST_ROOT/sounds.log"
STUB

cat >"$TEST_ROOT/bin/uwsm-app" <<'STUB'
#!/bin/bash
printf '<%s>' "$@" >"$TEST_ROOT/launch.args"
STUB

cat >"$TEST_ROOT/bin/stat" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ -f $TEST_ROOT/inject-shell-config-before-baseline \
    && ${!#} == "$HOME/.config/omarchy/shell.json" \
    && " $* " == *" %d:%i:%s:%a:%y:%z "* ]]; then
  /usr/bin/cp -- "$TEST_ROOT/concurrent-shell-config.json" "${!#}"
  rm -f "$TEST_ROOT/inject-shell-config-before-baseline"
fi
exec /usr/bin/stat "$@"
STUB

cat >"$TEST_ROOT/bin/capture-args" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_ROOT/captured.args"
printf '<%s>' "$@" >>"$TEST_ROOT/capture-history"
printf '\n' >>"$TEST_ROOT/capture-history"
STUB

cat >"$TEST_ROOT/bin/capture-hook" <<'STUB'
#!/bin/bash
printf '%s\n' "${OMACHORD_TRIGGER:-}" "${OMACHORD_HOOK:-}" \
  "${OMACHORD_ARG_1:-}" "${OMACHORD_ARG_2:-}" >"$TEST_ROOT/hook.env"
STUB

cat >"$TEST_ROOT/bin/always-fail" <<'STUB'
#!/bin/bash
printf '%s\n' 'deliberate failure' >&2
exit 42
STUB

cat >"$TEST_ROOT/bin/counting-fail" <<'STUB'
#!/bin/bash
count=$(cat "$TEST_ROOT/counting-fail.count" 2>/dev/null || printf 0)
printf '%s\n' "$((count + 1))" >"$TEST_ROOT/counting-fail.count"
exit 42
STUB

cat >"$TEST_ROOT/bin/should-not-run" <<'STUB'
#!/bin/bash
touch "$TEST_ROOT/should-not-run"
STUB

cat >"$TEST_ROOT/bin/omarchy-safe-echo" <<'STUB'
#!/bin/bash
printf '%s\n' "$@" >"$TEST_ROOT/omarchy-command.args"
STUB

cat >"$TEST_ROOT/bin/omarchy-unsafe" <<'STUB'
#!/bin/bash
touch "$TEST_ROOT/unsafe-ran"
STUB

cat >"$TEST_ROOT/bin/omarchy-shell" <<'STUB'
#!/bin/bash
set -euo pipefail
state="$TEST_ROOT/shell-state"
mkdir -p "$state"
printf '%s\n' "$*" >>"$TEST_ROOT/shell.log"
if [[ -f $TEST_ROOT/shell-down ]]; then
  echo "omarchy-shell is not running" >&2
  exit 1
fi
flag() { if [[ -f $state/$1 ]]; then echo true; else echo false; fi; }
[[ ${1:-} != -q ]] || shift
case "${1:-} ${2:-}" in
  "nightlight status") printf '{"enabled":%s,"temperature":4000}\n' "$(flag nightlight)" ;;
  "nightlight enable") touch "$state/nightlight"; echo enabled ;;
  "nightlight disable") rm -f "$state/nightlight"; echo disabled ;;
  "idle status")
    awake=$(flag stay-awake)
    if [[ $awake == true ]]; then idle=false; else idle=true; fi
    printf '{"enabled":%s,"stayAwake":%s,"idle":false}\n' "$idle" "$awake"
    ;;
  "idle enable") rm -f "$state/stay-awake"; echo enabled ;;
  "idle disable") touch "$state/stay-awake"; echo disabled ;;
  "notifications isDnd") if [[ -f $state/dnd ]]; then echo on; else echo off; fi ;;
  "notifications setDnd")
    case "${3:-}" in
      on)
        touch "$state/dnd"
        if [[ -f $TEST_ROOT/fail-after-dnd-set ]]; then
          rm -f "$TEST_ROOT/fail-after-dnd-set"
          echo "failed after changing do-not-disturb" >&2
          exit 1
        fi
        if [[ -f $TEST_ROOT/hold-after-dnd-set ]]; then
          touch "$TEST_ROOT/dnd-set"
          while [[ -f $TEST_ROOT/hold-after-dnd-set ]]; do sleep 0.01; done
        fi
        echo on
        ;;
      off) rm -f "$state/dnd"; echo off ;;
      *) echo "Too few arguments provided" >&2; exit 1 ;;
    esac
    ;;
  "shell putBarWidget")
    printf '%s %s\n' "${3:-}" "${4:-}" >>"$TEST_ROOT/widget.log"
    if [[ -f $TEST_ROOT/shell-scanning ]]; then
      echo "not ready"
    else
      # Like the real shell, the stub answers ok whether or not it placed the
      # widget; it only edits shell.json when asked to behave.
      if [[ -f $TEST_ROOT/shell-applies-widget ]]; then
        placed=$(jq -c --arg id "${3:-}" '
          ((.bar.layout.center | map(.id == "omarchy.indicators") | index(true) // -1) + 1) as $at
          | .bar.layout.center |= (.[:$at] + [{id: $id}] + .[$at:])
        ' "$HOME/.config/omarchy/shell.json")
        printf '%s\n' "$placed" >"$HOME/.config/omarchy/shell.json"
      fi
      echo ok
    fi
    ;;
  "shell reloadConfig")
    printf 'reloadConfig\n' >>"$TEST_ROOT/widget.log"
    echo ok
    ;;
  *) echo "Target not found." >&2; exit 1 ;;
esac
STUB

cat >"$TEST_ROOT/bin/omarchy-theme-current" <<'STUB'
#!/bin/bash
cat "$TEST_ROOT/theme.name" 2>/dev/null || echo Unknown
STUB

cat >"$TEST_ROOT/bin/omarchy-theme-list" <<'STUB'
#!/bin/bash
printf '%s\n' "Tokyo Night" "Gruvbox" "Catppuccin"
STUB

cat >"$TEST_ROOT/bin/omarchy-theme-set" <<'STUB'
#!/bin/bash
set -euo pipefail
name=$(echo "${1:-}" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
case $name in
  tokyo-night) display="Tokyo Night" ;;
  gruvbox) display="Gruvbox" ;;
  catppuccin) display="Catppuccin" ;;
  *) echo "Invalid theme name: ${1:-}" >&2; exit 1 ;;
esac
printf '%s\n' "$display" >"$TEST_ROOT/theme.name"
printf '%s\n' "$name" >>"$TEST_ROOT/theme.log"
# Omarchy runs the theme-set hook synchronously after applying a theme.
if ! "$OMACHORD_TEST_RUNNER" trigger hook theme-set "$name" >>"$TEST_ROOT/theme-hook.log" 2>&1; then
  [[ ! -f $TEST_ROOT/require-theme-hook-success ]] || exit 1
fi
STUB

cat >"$TEST_ROOT/bin/omarchy-brightness-display" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ ${1:-} == --no-osd ]] && shift
if [[ -f $TEST_ROOT/brightness-garbage ]]; then
  echo "n/a"
  exit 0
fi
if [[ $# -eq 0 ]]; then
  cat "$TEST_ROOT/brightness" 2>/dev/null || echo 80
  exit 0
fi
printf '%s\n' "${1%\%}" >"$TEST_ROOT/brightness"
STUB

mkdir -p "$TEST_ROOT/shadow"
cat >"$TEST_ROOT/shadow/omarchy-safe-echo" <<'STUB'
#!/bin/bash
touch "$TEST_ROOT/shadow-ran"
STUB

chmod +x "$TEST_ROOT/bin"/* "$TEST_ROOT/shadow"/*

export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$TEST_ROOT/config"
export XDG_STATE_HOME="$TEST_ROOT/state"
export XDG_DATA_HOME="$TEST_ROOT/data"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export PATH="$TEST_ROOT/shadow:$TEST_ROOT/bin:/usr/bin:/bin"
export OMACHORD_TEST_RUNNER="$RUNNER"
HYPR_CONFIG_DIR="$HOME/.config/hypr"
OMARCHY_CONFIG_DIR="$HOME/.config/omarchy"
HOOK_CONFIG_DIR="$OMARCHY_CONFIG_DIR/hooks"
CONFIG_PATH="$OMARCHY_CONFIG_DIR/omachord.json"
PLUGIN_DIR="$OMARCHY_CONFIG_DIR/plugins/anothadev.omachord"
ICON_FILE="$XDG_DATA_HOME/icons/hicolor/scalable/apps/anothadev.omachord.svg"
mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$HYPR_CONFIG_DIR" "$(dirname "$PLUGIN_DIR")"
ln -s "$ROOT" "$PLUGIN_DIR"

config_revision() {
  "$RUNNER" config snapshot | jq -er '.revision'
}

apply_config() {
  local payload=$1 revision=${2:-}
  [[ -n $revision ]] || revision=$(config_revision)
  printf '%s\n' "$payload" | "$RUNNER" config apply "$revision"
}

default_version=$($RUNNER config show | jq -r '.version')
assert_eq "$default_version" 1 "default config is schema version 1"
pass "default configuration"

if printf '%s\n' '{"version":1,"routines":[],"unknown":true}' | "$RUNNER" config validate >/dev/null; then
  fail "unknown top-level fields should fail validation"
fi
if printf '%s\n' '{"version":1,"routines":[{"id":"notice","name":"Notice","enabled":true,"triggers":[],"actions":[{"type":"notification","title":"-u","body":"","urgency":"low","glyph":""}]}]}' | "$RUNNER" config validate >/dev/null; then
  fail "notification option injection should fail validation"
fi
emoji=$(printf '\U0001F600%.0s' {1..100})
unicode_config=$(jq -cn --arg name "$emoji" '{version:1,routines:[{id:"unicode",name:$name,enabled:true,triggers:[],actions:[{type:"delay",milliseconds:0}]}]}')
printf '%s\n' "$unicode_config" | "$RUNNER" config validate | jq -e '.ok' >/dev/null
unicode_config=$(jq -cn --arg name "${emoji}$(printf '\U0001F600')" '{version:1,routines:[{id:"unicode",name:$name,enabled:true,triggers:[],actions:[{type:"delay",milliseconds:0}]}]}')
if printf '%s\n' "$unicode_config" | "$RUNNER" config validate >/dev/null; then
  fail "101-code-point routine name should fail validation"
fi
pass "strict schema validation"

oversized_config=$(mktemp)
truncate -s 1048577 "$oversized_config"
oversized_result=$(mktemp)
if "$RUNNER" config validate <"$oversized_config" >"$oversized_result"; then
  fail "oversized stdin configuration should fail"
fi
assert_eq "$(jq -r '.error' "$oversized_result")" "Configuration exceeds the 1 MiB limit"
if OMACHORD_CONFIG_FILE="$oversized_config" "$RUNNER" config show >"$oversized_result"; then
  fail "oversized canonical configuration should fail before copying"
fi
assert_eq "$(jq -r '.error' "$oversized_result")" "Configuration exceeds the 1 MiB limit"

nul_config=$(mktemp)
printf '{"version":1,\0"routines":[]}\n' >"$nul_config"
if "$RUNNER" config validate <"$nul_config" >/dev/null; then
  fail "embedded NUL configuration should not be transformed and accepted"
fi

fifo_config=$(mktemp -u "$TEST_ROOT/config-fifo.XXXXXX")
mkfifo "$fifo_config"
start=$(date +%s%3N)
if OMACHORD_CONFIG_FILE="$fifo_config" "$RUNNER" config show >/dev/null; then
  fail "FIFO configuration should be rejected"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 1000)) || fail "FIFO configuration blocked for ${elapsed}ms"

printf '{\n  "version": 1,\n  "routines": []\n}\n' \
  | "$RUNNER" config validate | jq -e '.ok' >/dev/null
rm -f -- "$oversized_config" "$oversized_result" "$nul_config" "$fifo_config"
pass "byte-bounded configuration input"

toggles_dir="$XDG_STATE_HOME/omarchy/toggles"
assert_eq "$("$RUNNER" toggles)" '[]' "missing toggle directory was not empty"
mkdir -p "$toggles_dir/subdirectory"
long_toggle=$(printf 'a%.0s' {1..64})
too_long_toggle="${long_toggle}a"
touch "$toggles_dir/scratch" "$toggles_dir/constructor" "$toggles_dir/$long_toggle" \
  "$toggles_dir/$too_long_toggle" "$toggles_dir/.hidden" "$toggles_dir/bad flag" \
  "$toggles_dir/a..b" "$toggles_dir/"$'bad\nline'
ln -s scratch "$toggles_dir/linked"
cat >"$TEST_ROOT/shadow/find" <<'STUB'
#!/bin/bash
touch "$TEST_ROOT/shadow-find-ran"
exit 1
STUB
chmod +x "$TEST_ROOT/shadow/find"
toggle_result=$("$RUNNER" toggles)
jq -e --arg long "$long_toggle" '
  . == (["scratch", "constructor", $long] | sort)
  and all(.[]; type == "string")
' <<<"$toggle_result" >/dev/null || fail "toggle scan accepted an invalid entry"
assert_missing "$TEST_ROOT/shadow-find-ran" "toggle scan used a PATH-shadowed find"
rm -f -- "$TEST_ROOT/shadow/find"
chmod 777 "$toggles_dir"
if "$RUNNER" toggles >/dev/null; then
  fail "toggle scan trusted an externally writable directory"
fi
chmod 755 "$toggles_dir"

rm -rf -- "$toggles_dir"
mkdir -p "$toggles_dir"
toggle_paths=()
for number in {0000..4096}; do toggle_paths+=("$toggles_dir/t$number"); done
touch "${toggle_paths[@]}"
toggle_limit_result=$(mktemp)
if "$RUNNER" toggles >"$toggle_limit_result"; then
  fail "toggle entry limit should reject 4097 entries"
fi
assert_eq "$(jq -r .code "$toggle_limit_result")" toggles-unavailable \
  "toggle entry limit returned the wrong error"
assert_file_contains "$toggle_limit_result" '4096 entry limit'

rm -rf -- "$toggles_dir"
mkdir -p "$toggles_dir"
toggle_paths=()
toggle_padding=$(printf 'x%.0s' {1..250})
for number in {0000..2040}; do toggle_paths+=("$toggles_dir/t$number$toggle_padding"); done
touch "${toggle_paths[@]}"
if "$RUNNER" toggles >"$toggle_limit_result"; then
  fail "toggle byte limit should reject an oversized directory scan"
fi
assert_eq "$(jq -r .code "$toggle_limit_result")" toggles-unavailable \
  "toggle byte limit returned the wrong error"
assert_file_contains "$toggle_limit_result" 'byte limit'
rm -rf -- "$toggles_dir"
rm -f -- "$toggle_limit_result"
pass "bounded trusted toggle discovery"

CONFIG=$(jq -cn '{
  version: 1,
  routines: [
    {
      id: "literal-args",
      name: "Literal arguments",
      enabled: true,
      triggers: [{type:"shortcut",keys:"SUPER + M",override:false}],
      actions: [{type:"exec",program:"capture-args",args:["space value","$(touch nope)","semi;colon","*.txt"]}]
    },
    {
      id: "stop-on-failure",
      name: "Stop on failure",
      enabled: true,
      triggers: [],
      actions: [
        {type:"exec",program:"always-fail",args:[]},
        {type:"exec",program:"should-not-run",args:[]}
      ]
    },
    {
      id: "boot-context",
      name: "Boot context",
      enabled: true,
      triggers: [{type:"hook",event:"post-boot"}],
      actions: [{type:"exec",program:"capture-hook",args:[]}]
    },
    {
      id: "microphone",
      name: "Microphone",
      enabled: true,
      triggers: [],
      actions: [{
        type:"microphone-toggle",
        sound:true,
        mutedSound:"/usr/share/sounds/freedesktop/stereo/service-logout.oga",
        liveSound:"/usr/share/sounds/freedesktop/stereo/service-login.oga"
      }]
    },
    {
      id: "safe-command",
      name: "Safe command",
      enabled: true,
      triggers: [],
      actions: [{type:"omarchy-command",route:"omarchy echo",args:["one value","two"]}]
    },
    {
      id: "timeout-descendants",
      name: "Timeout descendants",
      enabled: true,
      triggers: [],
      actions: [{type:"exec",program:"bash",args:["-c","sleep 3 & wait"]}]
    },
    {
      id: "background-child",
      name: "Background child",
      enabled: true,
      triggers: [],
      actions: [{type:"shell",command:"(sleep 0.2; touch \"$TEST_ROOT/background-finished\") >/dev/null 2>&1 &"}]
    },
    {
      id: "background-output",
      name: "Background output holder",
      enabled: true,
      triggers: [],
      actions: [{type:"shell",command:"(sleep 0.5; touch \"$TEST_ROOT/output-holder-survived\") &"}]
    },
    {
      id: "delay-lock",
      name: "Delay lock",
      enabled: true,
      triggers: [],
      actions: [{type:"delay",milliseconds:10000}]
    },
    {
      id: "post-supervisor",
      name: "Post-supervisor cleanup",
      enabled: true,
      triggers: [],
      actions: [{type:"shell",command:"(trap \"\" TERM; sleep 2; touch \"$TEST_ROOT/post-supervisor-survived\") & echo $! >\"$TEST_ROOT/post-holder.pid\"; touch \"$TEST_ROOT/post-ready\"; while [[ ! -e \"$TEST_ROOT/post-release\" ]]; do sleep 0.01; done"}]
    }
  ]
}')

apply_config "$CONFIG" | jq -e '.ok and (.connected | not)' >/dev/null
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "apply before Connect created integration"
assert_missing "$HOOK_CONFIG_DIR/post-boot.d/anothadev.omachord" "apply before Connect created hooks"
pass "disconnected apply stays disconnected"

stale_revision=$(config_revision)
CAS_FIRST=$(jq -c '.routines[0].name = "First concurrent edit"' <<<"$CONFIG")
CAS_SECOND=$(jq -c '.routines[0].name = "Second concurrent edit"' <<<"$CONFIG")
apply_config "$CAS_FIRST" "$stale_revision" | jq -e '.ok' >/dev/null
stale_result=$(mktemp)
if apply_config "$CAS_SECOND" "$stale_revision" >"$stale_result"; then
  fail "a stale full-document apply should not succeed"
fi
assert_eq "$(jq -r '.code' "$stale_result")" stale-config "stale apply returned the wrong error"
assert_eq "$(jq -r '.routines[0].name' "$CONFIG_PATH")" "First concurrent edit" \
  "stale apply overwrote the winning edit"
apply_config "$CONFIG" | jq -e '.ok' >/dev/null
rm -f -- "$stale_result"
pass "revision-based configuration apply"

state_dir="$XDG_STATE_HOME/omarchy/omachord"
chmod 755 "$state_dir"
"$RUNNER" status >/dev/null
assert_eq "$(stat -c %a "$state_dir")" 700 "state directory mode was not repaired"

# Read-only service probes must not touch metadata on the paths watched by
# Service.qml, or their chmod events feed straight back into another probe.
"$RUNNER" config snapshot >/dev/null
"$RUNNER" active >/dev/null
"$RUNNER" logs >/dev/null
metadata_before=$(find "$state_dir" -maxdepth 2 -printf '%p %C@\n' | sort)
"$RUNNER" status >/dev/null
"$RUNNER" config snapshot >/dev/null
"$RUNNER" active >/dev/null
"$RUNNER" logs >/dev/null
metadata_after=$(find "$state_dir" -maxdepth 2 -printf '%p %C@\n' | sort)
assert_eq "$metadata_after" "$metadata_before" "read-only probes changed watched state metadata"
pass "read-only probes preserve state metadata"

state_sentinel="$TEST_ROOT/state-sentinel"
printf '%s\n' 'state sentinel' >"$state_sentinel"
chmod 640 "$state_sentinel"
mv "$state_dir/config.lock" "$state_dir/config.lock.saved"
ln -s "$state_sentinel" "$state_dir/config.lock"
if "$RUNNER" status >/dev/null; then
  fail "symlinked configuration lock should be rejected"
fi
assert_eq "$(cat "$state_sentinel")" "state sentinel" "configuration lock target was changed"
assert_eq "$(stat -c %a "$state_sentinel")" 640 "configuration lock target mode was changed"
rm -f "$state_dir/config.lock"
mv "$state_dir/config.lock.saved" "$state_dir/config.lock"

ln -s "$state_sentinel" "$state_dir/runs.jsonl"
if "$RUNNER" logs >/dev/null; then
  fail "symlinked run history should be rejected"
fi
assert_eq "$(cat "$state_sentinel")" "state sentinel" "run-history target was changed"
assert_eq "$(stat -c %a "$state_sentinel")" 640 "run-history target mode was changed"
rm -f "$state_dir/runs.jsonl"

mkdir "$TEST_ROOT/poison-state-target"
chmod 700 "$TEST_ROOT/poison-state-target"
ln -s "$TEST_ROOT/poison-state-target" "$TEST_ROOT/poison-state"
if OMACHORD_STATE_DIR="$TEST_ROOT/poison-state" "$RUNNER" status >/dev/null; then
  fail "symlinked state directory should be rejected"
fi
assert_eq "$(find "$TEST_ROOT/poison-state-target" -mindepth 1 | wc -l)" 0 \
  "symlinked state directory target was populated"
rm -f "$TEST_ROOT/poison-state"

ln -s "$TEST_ROOT/poison-state-target" "$state_dir/backups"
if "$RUNNER" status >/dev/null; then
  fail "symlinked state child directory should be rejected"
fi
rm -f "$state_dir/backups"

mkdir -p -m 700 "$XDG_RUNTIME_DIR/omachord"
ln -s "$state_sentinel" "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"
if "$RUNNER" run literal-args test >/dev/null; then
  fail "symlinked routine lock should be rejected"
fi
assert_eq "$(cat "$state_sentinel")" "state sentinel" "routine lock target was changed"
assert_eq "$(stat -c %a "$state_sentinel")" 640 "routine lock target mode was changed"
rm -f "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock" "$state_sentinel"

ln -s "$TEST_ROOT/missing-lock-target" "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"
if "$RUNNER" run literal-args test >/dev/null; then
  fail "a dangling routine-lock symlink should be rejected"
fi
assert_missing "$TEST_ROOT/missing-lock-target" "a dangling lock symlink created its referent"
rm -f "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"

mkfifo "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"
chmod 600 "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"
start=$(date +%s%3N)
if "$RUNNER" run literal-args test >/dev/null; then
  fail "a FIFO routine lock should be rejected"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 1000)) || fail "FIFO routine lock blocked for ${elapsed}ms"
rm -f "$XDG_RUNTIME_DIR/omachord/routine-literal-args.lock"

mkfifo "$XDG_RUNTIME_DIR/omachord/resource-microphone.lock"
chmod 600 "$XDG_RUNTIME_DIR/omachord/resource-microphone.lock"
start=$(date +%s%3N)
if "$RUNNER" run microphone test >/dev/null; then
  fail "a FIFO microphone lock should be rejected"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 1000)) || fail "FIFO microphone lock blocked for ${elapsed}ms"
rm -f "$XDG_RUNTIME_DIR/omachord/resource-microphone.lock"

rm -f "$state_dir/runs.jsonl"
mkfifo "$state_dir/runs.jsonl"
chmod 600 "$state_dir/runs.jsonl"
start=$(date +%s%3N)
if "$RUNNER" logs >/dev/null; then
  fail "a FIFO run history should be rejected"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 1000)) || fail "FIFO run-history read blocked for ${elapsed}ms"
if "$RUNNER" run literal-args test >/dev/null; then
  fail "a FIFO run history should reject append"
fi
rm -f "$state_dir/runs.jsonl"

if grep -nE 'exec [6-9]<>"' "$RUNNER" \
  | grep -Fv '/proc/$opener_pid/fd/$opener_fd' >/dev/null; then
  fail "managed state paths still use direct read-write descriptor opens"
fi
pass "private non-following state paths"

printf '%s\n' '-- user bindings' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
"$RUNNER" autostart | jq -e '.ok and .connected' >/dev/null
assert_file_contains "$HYPR_CONFIG_DIR/bindings.lua" 'Oma Chord managed loader'
assert_eq "$(stat -c %a "$HYPR_CONFIG_DIR/bindings.lua")" 640 "Connect changed user bindings permissions"
assert_file_contains "$HYPR_CONFIG_DIR/omachord.lua" 'Omachord: Literal arguments'
luac -p "$HYPR_CONFIG_DIR/omachord.lua" || fail "generated Lua has invalid syntax"
if grep -Fq 'hl.unbind' "$HYPR_CONFIG_DIR/omachord.lua"; then
  fail "non-override shortcut emitted hl.unbind"
fi
hook_count=$(find "$HOOK_CONFIG_DIR" -type f -name anothadev.omachord | wc -l)
assert_eq "$hook_count" 6 "Connect should install six guarded hook wrappers"
[[ -f $XDG_STATE_HOME/omarchy/omachord/connection.json ]] || fail "connection ownership was not recorded"
jq -e '.version == 2 and .pluginId == "anothadev.omachord" and .loaderCreated and .iconCreated' \
  "$XDG_STATE_HOME/omarchy/omachord/connection.json" >/dev/null \
  || fail "Connect did not record application-icon ownership"
cmp -s "$XDG_DATA_HOME/applications/anothadev.omachord.desktop" "$ROOT/desktop/anothadev.omachord.desktop" \
  || fail "installed desktop entry differs from the repository template"
cmp -s "$ICON_FILE" "$ROOT/assets/omachord-icon.svg" \
  || fail "installed application icon differs from the repository asset"
assert_eq "$(stat -c %a "$ICON_FILE")" 644 "Connect installed the application icon with the wrong permissions"
"$RUNNER" status | jq -e '.connected and .ownedConnection and .integrationComplete' >/dev/null
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.disabled.json" "first-run autostart left a disable preference"
pass "default-on owned integration"

legacy_ownership='{"version":1,"pluginId":"anothadev.omachord","loaderCreated":true,"connectedAt":"2026-09-01T00:00:00+00:00"}'
printf '%s\n' "$legacy_ownership" >"$XDG_STATE_HOME/omarchy/omachord/connection.json"
printf '%s\n' 'user icon' >"$ICON_FILE"
if "$RUNNER" connect >/dev/null; then
  fail "legacy Repair should refuse an unowned application icon"
fi
assert_eq "$(cat "$ICON_FILE")" 'user icon' "legacy Repair overwrote an unowned application icon"
rm -f "$ICON_FILE"
"$RUNNER" connect | jq -e '.ok and .connected and .repaired' >/dev/null
jq -e '.version == 2 and .iconCreated' "$XDG_STATE_HOME/omarchy/omachord/connection.json" >/dev/null \
  || fail "legacy Repair did not record application-icon ownership"

printf '%s\n' "$legacy_ownership" >"$XDG_STATE_HOME/omarchy/omachord/connection.json"
printf '%s\n' 'user icon' >"$ICON_FILE"
"$RUNNER" disconnect | jq -e '.ok and (.connected | not)' >/dev/null
assert_eq "$(cat "$ICON_FILE")" 'user icon' "legacy Disconnect removed an unowned application icon"
rm -f "$ICON_FILE"
"$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
pass "legacy icon ownership migration"

sed -i -e '1s/^-- Generated by Omachord/-- Generated by Oma Chord/' \
  -e 's/"Omachord: /"Oma: /' "$HYPR_CONFIG_DIR/omachord.lua"
sed -i 's/^Name=Omachord$/Name=Oma Chord/' \
  "$XDG_DATA_HOME/applications/anothadev.omachord.desktop"
"$RUNNER" status | jq -e '.integrationComplete' >/dev/null
printf '%s\n' 'SUPER + M -> Oma: Literal arguments' >"$TEST_ROOT/bindings.txt"
"$RUNNER" bindings | jq -e '.[] | select(.keys == "SUPER + M") | .managed and .description == "Omachord: Literal arguments"' >/dev/null
"$RUNNER" autostart | jq -e '.ok and .connected and .repaired' >/dev/null
assert_file_contains "$HYPR_CONFIG_DIR/omachord.lua" 'Omachord: Literal arguments'
assert_file_contains "$XDG_DATA_HOME/applications/anothadev.omachord.desktop" 'Name=Omachord'
printf '%s\n' 'SUPER + M -> Omachord: Literal arguments' >"$TEST_ROOT/bindings.txt"
apply_config "$CONFIG" | jq -e '.ok and .connected' >/dev/null
assert_file_contains "$HYPR_CONFIG_DIR/omachord.lua" 'Omachord: Literal arguments'
pass "legacy display-name integration compatibility"
: >"$TEST_ROOT/bindings.txt"

connected_revision=$(config_revision)
CONNECTED_EDIT=$(jq -c '.routines[0].name = "Connected revision edit"' <<<"$CONFIG")
apply_config "$CONNECTED_EDIT" "$connected_revision" | jq -e '.ok and .connected' >/dev/null
connect_result=$(mktemp)
if "$RUNNER" connect "$connected_revision" >"$connect_result"; then
  fail "already-connected Connect accepted a stale revision"
fi
assert_eq "$(jq -r '.code' "$connect_result")" stale-config \
  "already-connected Connect returned the wrong stale-revision error"
apply_config "$CONFIG" | jq -e '.ok and .connected' >/dev/null
rm -f "$connect_result"
pass "already-connected revision validation"

UNCOMMITTED_CONFIG=$(jq -c '.routines += [{
  id:"uncommitted",
  name:"Uncommitted",
  enabled:true,
  triggers:[{type:"shortcut",keys:"SUPER + U",override:false}],
  actions:[{type:"exec",program:"should-not-run",args:[]}]
}]' <<<"$CONFIG")
uncommitted_revision=$(config_revision)
rm -f "$TEST_ROOT/reload-count" "$TEST_ROOT/reloaded" "$TEST_ROOT/should-not-run" \
  "$TEST_ROOT/config-published" "$TEST_ROOT/release-config-publish"
touch "$TEST_ROOT/error-after-reload"
printf '%s\n' "$UNCOMMITTED_CONFIG" \
  | env OMACHORD_FS_TEST_MATCH="$CONFIG_PATH" OMACHORD_FS_TEST_PAUSE=after-exchange \
      OMACHORD_FS_TEST_READY="$TEST_ROOT/config-published" \
      OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/release-config-publish" \
      "$RUNNER" config apply "$uncommitted_revision" >"$TEST_ROOT/uncommitted-apply.result" &
uncommitted_apply_pid=$!
for _ in {1..500}; do
  [[ -f $TEST_ROOT/config-published ]] && break
  sleep 0.01
done
[[ -f $TEST_ROOT/config-published ]] || fail "apply did not reach its pre-commit window"
"$RUNNER" run uncommitted test >"$TEST_ROOT/uncommitted-run.result" &
uncommitted_run_pid=$!
sleep 0.2
assert_missing "$TEST_ROOT/should-not-run" "uncommitted routine executed while apply was pending"
touch "$TEST_ROOT/release-config-publish"
set +e
wait "$uncommitted_apply_pid"
uncommitted_apply_status=$?
wait "$uncommitted_run_pid"
uncommitted_run_status=$?
set -e
((uncommitted_apply_status != 0)) || fail "forced apply rollback unexpectedly succeeded"
((uncommitted_run_status != 0)) || fail "rolled-back routine unexpectedly ran"
assert_missing "$TEST_ROOT/should-not-run" "rolled-back routine produced a side effect"
assert_eq "$(jq -r '.code' "$TEST_ROOT/uncommitted-apply.result")" reload-rolled-back \
  "forced apply did not report rollback"
"$RUNNER" status | jq -e '.integrationComplete and .configValid' >/dev/null
rm -f "$TEST_ROOT/error-after-reload" "$TEST_ROOT/config-published" \
  "$TEST_ROOT/release-config-publish" \
  "$TEST_ROOT/reload-count" "$TEST_ROOT/reloaded" \
  "$TEST_ROOT/uncommitted-apply.result" "$TEST_ROOT/uncommitted-run.result"

printf '%s\n' "$UNCOMMITTED_CONFIG" >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
uncommitted_result=$(mktemp)
if "$RUNNER" run uncommitted test >"$uncommitted_result"; then
  fail "configuration without a matching commit marker executed"
fi
assert_eq "$(jq -r '.code' "$uncommitted_result")" uncommitted-config \
  "commit-marker mismatch returned the wrong error"
assert_missing "$TEST_ROOT/should-not-run" "commit-marker mismatch produced a side effect"
printf '%s\n' "$CONFIG" >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
"$RUNNER" status | jq -e '.integrationComplete and .configValid' >/dev/null
rm -f "$uncommitted_result"
pass "uncommitted routines remain non-executable"

literal_result=$(mktemp)
if ! "$RUNNER" run literal-args test >"$literal_result"; then
  fail "literal argv routine failed: $(cat "$literal_result")"
fi
jq -e '.ok' "$literal_result" >/dev/null
rm -f "$literal_result"
mapfile -t literal_args <"$TEST_ROOT/captured.args"
assert_eq "${literal_args[0]}" 'space value'
assert_eq "${literal_args[1]}" '$(touch nope)'
assert_eq "${literal_args[2]}" 'semi;colon'
assert_eq "${literal_args[3]}" '*.txt'
assert_missing "$ROOT/nope" "literal argument executed as shell syntax"
assert_eq "$(stat -c %a "$XDG_STATE_HOME/omarchy/omachord/runs.jsonl")" 600 "run history is not private"
pass "argv remains literal"

chmod 644 "$XDG_STATE_HOME/omarchy/omachord/runs.jsonl"
if "$RUNNER" run stop-on-failure test >/dev/null; then
  fail "failing action should fail its routine"
fi
assert_missing "$TEST_ROOT/should-not-run" "routine continued after an action failure"
assert_eq "$(stat -c %a "$XDG_STATE_HOME/omarchy/omachord/runs.jsonl")" 600 "existing run history permissions were not repaired"
pass "stop on first action failure"

OMACHORD_ARG_2=stale "$HOOK_CONFIG_DIR/post-boot.d/anothadev.omachord" "context value" | jq -e '.ok' >/dev/null
mapfile -t hook_env <"$TEST_ROOT/hook.env"
assert_eq "${hook_env[0]}" hook
assert_eq "${hook_env[1]}" post-boot
assert_eq "${hook_env[2]}" 'context value'
assert_eq "${hook_env[3]}" '' "hook inherited a stale higher argument"
OMACHORD_HOOK=fake OMACHORD_ARG_1=stale OMACHORD_ARG_2=stale \
  "$RUNNER" run boot-context test | jq -e '.ok' >/dev/null
mapfile -t hook_env <"$TEST_ROOT/hook.env"
assert_eq "${hook_env[0]}" test
assert_eq "${hook_env[1]}" '' "manual run inherited a hook event"
assert_eq "${hook_env[2]}" '' "manual run inherited hook argument 1"
assert_eq "${hook_env[3]}" '' "manual run inherited hook argument 2"
pass "isolated hook context and dispatch"

"$RUNNER" run microphone test | jq -e '.ok' >/dev/null
wait_for_file_contains "$TEST_ROOT/sounds.log" 'service-logout.oga'
"$RUNNER" run microphone test | jq -e '.ok' >/dev/null
wait_for_file_contains "$TEST_ROOT/sounds.log" 'service-login.oga'
pass "microphone state sounds"

"$RUNNER" run safe-command test | jq -e '.ok' >/dev/null
mapfile -t command_args <"$TEST_ROOT/omarchy-command.args"
assert_eq "${command_args[0]}" 'one value'
assert_eq "${command_args[1]}" two
assert_missing "$TEST_ROOT/shadow-ran" "PATH-shadowed Omarchy binary was executed"
"$RUNNER" commands | jq -e 'any(.[]; .route == "omarchy echo")' >/dev/null
pass "Omarchy aliases and metadata-directory dispatch"

touch "$TEST_ROOT/control-output-child"
start=$(date +%s%3N)
OMACHORD_CONTROL_TIMEOUT=0.1s "$RUNNER" commands \
  | jq -e 'any(.[]; .route == "omarchy echo")' >/dev/null
elapsed=$(($(date +%s%3N) - start))
((elapsed < 2000)) || fail "control capture waited ${elapsed}ms for an output-holding descendant"
touch "$TEST_ROOT/control-output-overflow"
overflow_result=$(mktemp)
if OMACHORD_CONTROL_TIMEOUT=2s "$RUNNER" commands >"$overflow_result"; then
  fail "oversized control output should fail"
fi
for _ in {1..500}; do
  [[ -s $TEST_ROOT/control-overflow.pid ]] && break
  sleep 0.002
done
[[ -s $TEST_ROOT/control-overflow.pid ]] || fail "control overflow descendant did not start"
overflow_pid=$(cat "$TEST_ROOT/control-overflow.pid")
overflow_alive=false
for _ in {1..100}; do
  if [[ ! -r /proc/$overflow_pid/stat ]] \
    || [[ $(awk '{print $3}' "/proc/$overflow_pid/stat") == Z ]]; then
    break
  fi
  overflow_alive=true
  sleep 0.002
done
if [[ $overflow_alive == true ]] && [[ -r /proc/$overflow_pid/stat ]] \
  && [[ $(awk '{print $3}' "/proc/$overflow_pid/stat") != Z ]]; then
  kill -KILL "$overflow_pid" 2>/dev/null || true
  fail "control output overflow stranded its descendant"
fi
assert_missing "$TEST_ROOT/control-overflow-survived"
rm -f "$overflow_result" "$TEST_ROOT/control-overflow.pid"
pass "bounded control-command descendants"

printf '%s\n' 'BROKEN OMA LUA' >"$HYPR_CONFIG_DIR/omachord.lua"
apply_config "$CONFIG" | jq -e '.ok and .connected' >/dev/null
luac -p "$HYPR_CONFIG_DIR/omachord.lua" || fail "save did not repair owned generated Lua"
pass "owned generated-Lua recovery on save"

chmod 666 "$CONFIG_PATH"
unsafe_result=$(mktemp)
if "$RUNNER" run literal-args test >"$unsafe_result"; then
  fail "runner executed a world-writable configuration"
fi
assert_eq "$(jq -r '.code' "$unsafe_result")" unsafe-config "unsafe configuration returned the wrong error"
"$RUNNER" status | jq -e '(.configValid | not) and (.integrationComplete | not)' >/dev/null
if "$RUNNER" connect >/dev/null; then
  fail "Connect trusted an externally writable configuration"
fi
assert_eq "$(stat -c %a "$CONFIG_PATH")" 666 "rejected Connect changed configuration permissions"
chmod 600 "$CONFIG_PATH"
"$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
rm -f "$unsafe_result"
pass "unsafe configuration execution and activation guard"

start=$(date +%s%3N)
if OMACHORD_ACTION_TIMEOUT=0.2s "$RUNNER" run timeout-descendants test >/dev/null; then
  fail "timed-out descendant routine should fail"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 2000)) || fail "action timeout waited ${elapsed}ms for a descendant"
"$RUNNER" run background-child test | jq -e '.ok' >/dev/null
"$RUNNER" run background-child test | jq -e '.ok' >/dev/null
sleep 0.4
[[ -f $TEST_ROOT/background-finished ]] || fail "output-detached background action was terminated"
start=$(date +%s%3N)
"$RUNNER" run background-output test | jq -e '.ok' >/dev/null
elapsed=$(($(date +%s%3N) - start))
((elapsed < 2000)) || fail "runner waited ${elapsed}ms for a completed action's background child"
sleep 0.7
assert_missing "$TEST_ROOT/output-holder-survived" "output-holding background action escaped cleanup"
pass "bounded descendants and non-leaking locks"

"$RUNNER" run delay-lock test >"$TEST_ROOT/delay-result" &
delay_runner=$!
delay_timeout=""
delay_child=""
for _ in {1..100}; do
  delay_timeout=$(action_timeout_for "$delay_runner" || true)
  [[ -z $delay_timeout ]] || delay_child=$(pgrep -P "$delay_timeout" -x sleep 2>/dev/null || true)
  [[ -z $delay_child ]] || break
  sleep 0.01
done
[[ -n $delay_child ]] || fail "delay action did not start"
kill -TERM "$delay_runner"
wait "$delay_runner" 2>/dev/null || true
if kill -0 "$delay_child" 2>/dev/null; then
  kill "$delay_child" 2>/dev/null || true
  fail "terminated runner left its delay action alive"
fi
if ! flock -n "$XDG_RUNTIME_DIR/omachord/routine-delay-lock.lock" true; then
  fail "terminated delay child retained the routine lock"
fi
rm -f "$TEST_ROOT/delay-result"

"$RUNNER" run delay-lock test >"$TEST_ROOT/delay-kill-result" &
delay_runner=$!
delay_timeout=""
delay_child=""
for _ in {1..100}; do
  delay_timeout=$(action_timeout_for "$delay_runner" || true)
  [[ -z $delay_timeout ]] || delay_child=$(pgrep -P "$delay_timeout" -x sleep 2>/dev/null || true)
  [[ -z $delay_child ]] || break
  sleep 0.01
done
[[ -n $delay_child ]] || fail "SIGKILL lock test did not start its action"
if flock -n "$XDG_RUNTIME_DIR/omachord/routine-delay-lock.lock" true; then
  fail "routine lock was available while its action was alive"
fi
kill -KILL "$delay_runner"
wait "$delay_runner" 2>/dev/null || true
lock_released=false
for _ in {1..100}; do
  if ! kill -0 "$delay_child" 2>/dev/null \
    && flock -n "$XDG_RUNTIME_DIR/omachord/routine-delay-lock.lock" true; then
    lock_released=true
    break
  fi
  sleep 0.01
done
[[ $lock_released == true ]] || fail "action supervisor retained the routine lock after termination"
rm -f "$TEST_ROOT/delay-kill-result"
pass "runner termination preserves action and lock ownership"

rm -f "$TEST_ROOT/post-supervisor-survived" "$TEST_ROOT/post-holder.pid" \
  "$TEST_ROOT/post-ready" "$TEST_ROOT/post-release"
setsid "$RUNNER" run post-supervisor test >"$TEST_ROOT/post-supervisor.result" &
post_runner=$!
post_timeout=""
for _ in {1..500}; do
  post_timeout=$(action_timeout_for "$post_runner" || true)
  [[ -z $post_timeout || ! -s $TEST_ROOT/post-holder.pid || ! -e $TEST_ROOT/post-ready ]] || break
  sleep 0.002
done
[[ -n $post_timeout ]] || fail "post-supervisor cleanup test did not start"
[[ -s $TEST_ROOT/post-holder.pid && -e $TEST_ROOT/post-ready ]] \
  || fail "post-supervisor cleanup test did not become ready"
post_holder=$(cat "$TEST_ROOT/post-holder.pid")
post_start=$(awk '{print $22}' "/proc/$post_timeout/stat")
kill -STOP "$post_runner"
touch "$TEST_ROOT/post-release"
post_anchored=false
for _ in {1..500}; do
  if [[ -r /proc/$post_timeout/stat ]] \
    && [[ $(awk '{print $3}' "/proc/$post_timeout/stat") == Z ]]; then
    post_anchored=true
    break
  fi
  sleep 0.002
done
[[ $post_anchored == true ]] || fail "exited timeout leader was not retained"
assert_eq "$(awk '{print $22}' "/proc/$post_timeout/stat")" "$post_start" \
  "retained timeout identity changed"
assert_eq "$(awk '{print $5}' "/proc/$post_timeout/stat")" "$post_timeout" \
  "retained timeout does not anchor its process group"
assert_eq "$(awk '{print $5}' "/proc/$post_holder/stat")" "$post_timeout" \
  "output holder is not in the anchored action group"
kill -KILL -- "-$post_runner"
wait "$post_runner" 2>/dev/null || true
for _ in {1..500}; do
  ! kill -0 "$post_holder" 2>/dev/null && break
  sleep 0.004
done
if kill -0 "$post_holder" 2>/dev/null; then
  fail "output-holding descendant survived anchored supervisor cleanup"
fi
assert_missing "$TEST_ROOT/post-supervisor-survived" \
  "output-holding descendant survived a post-supervisor SIGKILL"
if ! flock -n "$XDG_RUNTIME_DIR/omachord/routine-post-supervisor.lock" true; then
  fail "post-supervisor guard retained the routine lock after cleanup"
fi
rm -f "$TEST_ROOT/post-supervisor.result" "$TEST_ROOT/post-holder.pid" \
  "$TEST_ROOT/post-ready" "$TEST_ROOT/post-release"

zombie_pid_file="$TEST_ROOT/zombie-runner.pid"
rm -f "$zombie_pid_file"
perl -e '
  my ($pid_file, @command) = @ARGV;
  my $pid = fork();
  die "fork: $!" unless defined $pid;
  if ($pid == 0) { exec @command; die "exec: $!"; }
  open my $handle, ">", $pid_file or die "open: $!";
  print {$handle} "$pid\n";
  close $handle;
  sleep 10;
' "$zombie_pid_file" "$RUNNER" run delay-lock test \
  >"$TEST_ROOT/zombie-runner.result" 2>/dev/null &
zombie_holder=$!
for _ in {1..500}; do
  [[ -s $zombie_pid_file ]] && break
  sleep 0.002
done
[[ -s $zombie_pid_file ]] || fail "zombie guard test did not start its runner"
zombie_runner=$(cat "$zombie_pid_file")
zombie_timeout=""
for _ in {1..500}; do
  zombie_timeout=$(action_timeout_for "$zombie_runner" || true)
  [[ -z $zombie_timeout ]] || break
  sleep 0.002
done
[[ -n $zombie_timeout ]] || fail "zombie guard test did not start its action"
kill -KILL "$zombie_runner"
zombie_observed=false
for _ in {1..500}; do
  if [[ -r /proc/$zombie_runner/stat ]] \
    && [[ $(awk '{print $3}' "/proc/$zombie_runner/stat") == Z ]]; then
    zombie_observed=true
    break
  fi
  sleep 0.002
done
[[ $zombie_observed == true ]] || fail "killed runner was reaped before the zombie test"
zombie_lock_released=false
for _ in {1..500}; do
  if flock -n "$XDG_RUNTIME_DIR/omachord/routine-delay-lock.lock" true; then
    zombie_lock_released=true
    break
  fi
  sleep 0.004
done
[[ $zombie_lock_released == true ]] || fail "zombie runner retained its routine lock"
kill "$zombie_holder" 2>/dev/null || true
wait "$zombie_holder" 2>/dev/null || true
rm -f "$zombie_pid_file" "$TEST_ROOT/zombie-runner.result"
pass "post-supervisor and zombie action cleanup"

env -u XDG_RUNTIME_DIR "$RUNNER" run literal-args test | jq -e '.ok' >/dev/null
assert_eq "$(stat -c %a "$XDG_STATE_HOME/omarchy/omachord/runtime")" 700 "fallback lock directory is not private"
pass "private runtime-lock fallback"

OLD_CONFIG=$(cat "$CONFIG_PATH")
ROLLBACK_CONFIG=$(jq -c '.routines[0].name = "Should roll back"' <<<"$CONFIG")
rm -f "$TEST_ROOT/reloaded" "$TEST_ROOT/reload-count"
touch "$TEST_ROOT/error-after-reload"
rollback_result=$(mktemp)
if apply_config "$ROLLBACK_CONFIG" >"$rollback_result"; then
  fail "post-reload config error should fail apply"
fi
assert_eq "$(jq -r '.code' "$rollback_result")" reload-rolled-back "successful recovery reload was not reported"
assert_eq "$(cat "$CONFIG_PATH")" "$OLD_CONFIG" "failed apply did not restore config"
assert_eq "$(cat "$TEST_ROOT/reload-count")" 2 "rollback should reload the restored configuration"
rm -f "$rollback_result" "$TEST_ROOT/error-after-reload" "$TEST_ROOT/reloaded" "$TEST_ROOT/reload-count"
pass "reload rollback"

touch "$TEST_ROOT/always-error-after-reload"
rollback_result=$(mktemp)
if apply_config "$ROLLBACK_CONFIG" >"$rollback_result"; then
  fail "persistent recovery error should fail apply"
fi
assert_eq "$(jq -r '.code' "$rollback_result")" rollback-failed "failed recovery reload was mislabeled"
rm -f "$rollback_result" "$TEST_ROOT/always-error-after-reload" "$TEST_ROOT/reloaded" "$TEST_ROOT/reload-count"
pass "rollback reload failure reporting"

rm -f "$TEST_ROOT/config-rollback-ready" "$TEST_ROOT/config-rollback-release" \
  "$TEST_ROOT/config-rollback-count"
touch "$TEST_ROOT/error-after-reload"
rollback_result=$(mktemp)
printf '%s\n' "$ROLLBACK_CONFIG" \
  | env OMACHORD_FS_TEST_MATCH="$CONFIG_PATH" OMACHORD_FS_TEST_PAUSE=before-publish \
      OMACHORD_FS_TEST_ORDINAL=2 \
      OMACHORD_FS_TEST_COUNT_FILE="$TEST_ROOT/config-rollback-count" \
      OMACHORD_FS_TEST_READY="$TEST_ROOT/config-rollback-ready" \
      OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/config-rollback-release" \
      "$RUNNER" config apply "$(config_revision)" >"$rollback_result" &
rollback_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/config-rollback-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/config-rollback-ready ]] || fail "rollback did not reach its compare-and-swap"
printf '%s\n' 'concurrently edited configuration' >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
touch "$TEST_ROOT/config-rollback-release"
if wait "$rollback_pid"; then fail "concurrent rollback edit should prevent restoration"; fi
assert_eq "$(jq -r '.code' "$rollback_result")" rollback-failed "concurrent rollback edit was not reported"
assert_eq "$(cat "$CONFIG_PATH")" 'concurrently edited configuration' "rollback overwrote a concurrent configuration edit"
printf '%s\n' "$OLD_CONFIG" >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
rm -f "$rollback_result" "$TEST_ROOT/error-after-reload" "$TEST_ROOT/config-rollback-ready" \
  "$TEST_ROOT/config-rollback-release" "$TEST_ROOT/config-rollback-count" \
  "$TEST_ROOT/reloaded" "$TEST_ROOT/reload-count"
"$RUNNER" status | jq -e '.integrationComplete and .configValid' >/dev/null
pass "rollback preserves concurrent edits"

"$RUNNER" disconnect | jq -e '.ok and (.connected | not)' >/dev/null
assert_missing "$HYPR_CONFIG_DIR/omachord.lua"
assert_missing "$XDG_DATA_HOME/applications/anothadev.omachord.desktop"
assert_missing "$ICON_FILE"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json"
[[ -f $XDG_STATE_HOME/omarchy/omachord/connection.disabled.json ]] \
  || fail "Disconnect did not persist the disabled preference"
"$RUNNER" status | jq -e '(.connectionEnabled | not) and (.integrationComplete | not)' >/dev/null
assert_eq "$(stat -c %a "$HYPR_CONFIG_DIR/bindings.lua")" 640 "Disconnect changed user bindings permissions"
[[ -f $CONFIG_PATH ]] || fail "Disconnect removed routine data"
backup_count=$(find "$XDG_STATE_HOME/omarchy/omachord/backups" -type f -name 'bindings.lua.*' | wc -l)
((backup_count >= 2)) || fail "same-second transactions overwrote a bindings backup"

EMPTY='{"version":1,"routines":[]}'
apply_config "$EMPTY" | jq -e '.ok and (.connected | not)' >/dev/null
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "apply after Disconnect reactivated integration"
"$RUNNER" autostart | jq -e '.ok and .disabled and .skipped and (.connected | not)' >/dev/null
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "autostart ignored an explicit Disconnect"
pass "Disconnect persists across later saves"

CONCURRENT_CONFIG='{"version":1,"routines":[{"id":"concurrent","name":"Concurrent edit","enabled":true,"triggers":[],"actions":[{"type":"delay","milliseconds":0}]}]}'
panel_revision=$(config_revision)
printf '%s\n' "$CONCURRENT_CONFIG" >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
connect_result=$(mktemp)
if "$RUNNER" connect "$panel_revision" >"$connect_result"; then
  fail "revision-bound Connect accepted a newer configuration"
fi
assert_eq "$(jq -r '.code' "$connect_result")" stale-config \
  "revision-bound Connect returned the wrong error"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" \
  "stale panel Connect claimed integration ownership"
apply_config "$EMPTY" | jq -e '.ok and (.connected | not)' >/dev/null
rm -f "$connect_result"

printf '%s\n' "$CONCURRENT_CONFIG" >"$TEST_ROOT/concurrent-config.json"
# No-shortcut documents skip the catalogue. Give the mock a reason to run so
# it still injects an external edit during shortcut preflight.
apply_config "$CONFIG" >/dev/null
touch "$TEST_ROOT/inject-connect-config-race"
connect_result=$(mktemp)
if "$RUNNER" connect >"$connect_result"; then
  fail "Connect overwrote a configuration edited after its initial read"
fi
assert_eq "$(jq -r '.code' "$connect_result")" concurrent-edit \
  "stale Connect returned the wrong error"
jq -e '.routines[0].id == "concurrent"' "$CONFIG_PATH" >/dev/null \
  || fail "stale Connect did not preserve the concurrent configuration"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" \
  "stale Connect claimed integration ownership"
if grep -Fq 'Oma Chord managed loader' "$HYPR_CONFIG_DIR/bindings.lua"; then
  fail "stale Connect installed its loader"
fi
apply_config "$EMPTY" | jq -e '.ok and (.connected | not)' >/dev/null
rm -f "$connect_result" "$TEST_ROOT/concurrent-config.json"
pass "Connect configuration compare-and-swap"

apply_config "$CONFIG" >/dev/null
touch "$TEST_ROOT/inject-connect-large-config-race"
connect_result=$(mktemp)
start=$(date +%s%3N)
if "$RUNNER" connect >"$connect_result"; then
  fail "Connect accepted an oversized configuration raced into snapshotting"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 2000)) || fail "bounded transaction snapshot took ${elapsed}ms"
assert_eq "$(stat -c %s "$CONFIG_PATH")" 1073741824 \
  "failed Connect changed the raced oversized configuration"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" \
  "oversized-race Connect claimed integration ownership"
printf '%s\n' "$CONFIG" >"$CONFIG_PATH"
chmod 600 "$CONFIG_PATH"
"$RUNNER" config snapshot | jq -e --argjson config "$CONFIG" '.committed and .config == $config' >/dev/null
apply_config "$EMPTY" >/dev/null
rm -f "$connect_result"
pass "bounded transaction config snapshots"

printf '%s\n' 'unowned' >"$HYPR_CONFIG_DIR/omachord.lua"
if "$RUNNER" connect >/dev/null; then
  fail "Connect should refuse an unowned generated-file collision"
fi
assert_eq "$(cat "$HYPR_CONFIG_DIR/omachord.lua")" unowned
rm -f "$HYPR_CONFIG_DIR/omachord.lua"
mkdir -p "$(dirname "$ICON_FILE")"
printf '%s\n' 'unowned' >"$ICON_FILE"
if "$RUNNER" connect >/dev/null; then
  fail "Connect should refuse an unowned application-icon collision"
fi
assert_eq "$(cat "$ICON_FILE")" unowned "Connect overwrote an unowned application icon"
rm -f "$ICON_FILE"
pass "unowned artifact collision"

touch "$TEST_ROOT/create-connect-collision"
connect_result=$(mktemp)
if "$RUNNER" connect >"$connect_result"; then
  fail "Connect overwrote an unowned file created during preflight"
fi
assert_eq "$(cat "$HYPR_CONFIG_DIR/omachord.lua")" 'concurrently created' "concurrent file was overwritten"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "failed fresh Connect claimed ownership"
if grep -Fq 'Oma Chord managed loader' "$HYPR_CONFIG_DIR/bindings.lua"; then
  fail "concurrent-collision Connect installed its loader"
fi
rm -f "$connect_result" "$HYPR_CONFIG_DIR/omachord.lua"
pass "concurrent Connect collision"

touch "$TEST_ROOT/create-loader-collision"
connect_result=$(mktemp)
if "$RUNNER" connect >"$connect_result"; then
  fail "Connect claimed a loader line created during preflight"
fi
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "loader-collision Connect claimed ownership"
loader_count=$(grep -Fxc 'require("default.hypr.require_optional").module("hypr.omachord") -- Oma Chord managed loader' "$HYPR_CONFIG_DIR/bindings.lua")
assert_eq "$loader_count" 1 "concurrent loader line was changed"
grep -Fvx 'require("default.hypr.require_optional").module("hypr.omachord") -- Oma Chord managed loader' \
  "$HYPR_CONFIG_DIR/bindings.lua" >"$HYPR_CONFIG_DIR/bindings.lua.clean" || true
mv "$HYPR_CONFIG_DIR/bindings.lua.clean" "$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
rm -f "$connect_result"
pass "concurrent loader collision"

printf '%s\n' 'bindings before transaction' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
rm -f "$TEST_ROOT/bindings-race-ready" "$TEST_ROOT/bindings-race-release"
connect_result=$(mktemp)
env OMACHORD_FS_TEST_MATCH="$HYPR_CONFIG_DIR/bindings.lua" \
  OMACHORD_FS_TEST_PAUSE=before-publish \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/bindings-race-ready" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/bindings-race-release" \
  "$RUNNER" connect >"$connect_result" &
connect_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/bindings-race-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/bindings-race-ready ]] || fail "bindings write did not reach compare-and-swap"
printf '%s\n' 'concurrently edited bindings' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
touch "$TEST_ROOT/bindings-race-release"
if wait "$connect_pid"; then fail "Connect overwrote bindings edited at atomic replacement"; fi
assert_eq "$(cat "$HYPR_CONFIG_DIR/bindings.lua")" 'concurrently edited bindings' "atomic replacement lost a concurrent bindings edit"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "failed binding transaction claimed ownership"
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "failed binding transaction installed generated Lua"
rm -f "$connect_result" "$TEST_ROOT/bindings-race-ready" "$TEST_ROOT/bindings-race-release"
pass "atomic bindings collision"

printf '%s\n' '-- user bindings' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
rm -f "$TEST_ROOT/ownership-race-ready" "$TEST_ROOT/ownership-race-release"
connect_result=$(mktemp)
env OMACHORD_FS_TEST_MATCH="$XDG_STATE_HOME/omarchy/omachord/connection.json" \
  OMACHORD_FS_TEST_PAUSE=before-publish \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/ownership-race-ready" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/ownership-race-release" \
  "$RUNNER" connect >"$connect_result" &
connect_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/ownership-race-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/ownership-race-ready ]] || fail "ownership write did not reach compare-and-swap"
printf '%s\n' 'concurrently created ownership' >"$XDG_STATE_HOME/omarchy/omachord/connection.json"
chmod 600 "$XDG_STATE_HOME/omarchy/omachord/connection.json"
touch "$TEST_ROOT/ownership-race-release"
if wait "$connect_pid"; then fail "Connect overwrote ownership created at atomic installation"; fi
assert_eq "$(cat "$XDG_STATE_HOME/omarchy/omachord/connection.json")" 'concurrently created ownership' "atomic installation lost concurrent ownership"
if grep -Fq 'Oma Chord managed loader' "$HYPR_CONFIG_DIR/bindings.lua"; then
  fail "ownership-collision Connect installed its loader"
fi
rm -f "$connect_result" "$TEST_ROOT/ownership-race-ready" "$TEST_ROOT/ownership-race-release" \
  "$XDG_STATE_HOME/omarchy/omachord/connection.json"
pass "atomic ownership collision"

printf '%s\n' 'bindings before failed exchange-back' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
rm -f "$TEST_ROOT/exchange-back-ready" "$TEST_ROOT/exchange-back-release"
connect_result=$(mktemp)
env OMACHORD_FS_TEST_MATCH="$HYPR_CONFIG_DIR/bindings.lua" \
  OMACHORD_FS_TEST_PAUSE=before-exchange \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/exchange-back-ready" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/exchange-back-release" \
  "$RUNNER" connect >"$connect_result" &
connect_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/exchange-back-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/exchange-back-ready ]] || fail "bindings update did not reach its race window"
printf '%s\n' 'concurrent version from failed exchange-back' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
touch "$TEST_ROOT/exchange-back-release"
if wait "$connect_pid"; then fail "Connect succeeded after a post-check bindings edit"; fi
assert_eq "$(jq -r '.code' "$connect_result")" rollback-failed "post-check edit was not reported as a concurrent rollback conflict"
assert_eq "$(cat "$HYPR_CONFIG_DIR/bindings.lua")" 'concurrent version from failed exchange-back' "compare-mismatch recovery lost the concurrent bindings"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "compare-mismatch recovery left ownership state"
[[ -f $XDG_STATE_HOME/omarchy/omachord/connection.disabled.json ]] \
  || fail "failed Enable discarded the disabled preference"
rm -f "$connect_result" "$TEST_ROOT/exchange-back-ready" "$TEST_ROOT/exchange-back-release"
pass "post-check compare-mismatch recovery"

printf '%s\n' 'open descriptor baseline' >"$HYPR_CONFIG_DIR/bindings.lua"
chmod 640 "$HYPR_CONFIG_DIR/bindings.lua"
(
  exec 8>>"$HYPR_CONFIG_DIR/bindings.lua"
  touch "$TEST_ROOT/open-fd-ready"
  for _ in {1..500}; do
    [[ ! -f $TEST_ROOT/write-open-fd-now ]] || break
    sleep 0.01
  done
  printf '%s\n' 'late write through open descriptor' >&8
  touch "$TEST_ROOT/open-fd-written"
) &
fd_writer=$!
for _ in {1..500}; do
  [[ ! -f $TEST_ROOT/open-fd-ready ]] || break
  sleep 0.01
done
"$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.disabled.json" "successful Enable kept the disabled preference"
touch "$TEST_ROOT/write-open-fd-now"
wait "$fd_writer"
find "$XDG_STATE_HOME/omarchy/omachord/retired" -type f -exec grep -Fl 'late write through open descriptor' {} + \
  | grep -q . || fail "post-fingerprint open-FD write was lost"
rm -f "$TEST_ROOT/open-fd-ready" "$TEST_ROOT/open-fd-written" "$TEST_ROOT/write-open-fd-now"
"$RUNNER" disconnect | jq -e '.ok and (.connected | not)' >/dev/null
pass "open descriptor version preservation"

retired_before=$(find "$XDG_STATE_HOME/omarchy/omachord/retired" -type f | wc -l)
for _ in {1..10}; do
  apply_config "$EMPTY" | jq -e '.ok and (.connected | not)' >/dev/null
done
retired_after=$(find "$XDG_STATE_HOME/omarchy/omachord/retired" -type f | wc -l)
assert_eq "$retired_after" "$retired_before" "ordinary saves accumulated retired inodes"
pass "bounded retired inode preservation"

blocked_parent="$TEST_ROOT/blocked-desktop-parent"
printf '%s\n' blocked >"$blocked_parent"
connect_result=$(mktemp)
if OMACHORD_DESKTOP_FILE="$blocked_parent/anothadev.omachord.desktop" "$RUNNER" connect >"$connect_result" 2>"$TEST_ROOT/connect.stderr"; then
  fail "mid-Connect desktop write failure should fail"
fi
assert_eq "$(jq -r '.code' "$connect_result")" connect-rolled-back "partial Connect was not rolled back"
if grep -Fq 'Oma Chord managed loader' "$HYPR_CONFIG_DIR/bindings.lua"; then
  fail "failed Connect left its loader installed"
fi
assert_missing "$ICON_FILE" "failed Connect installed an application icon"
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "failed Connect left generated Lua"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "failed Connect left ownership state"
hook_count=$(find "$HOOK_CONFIG_DIR" -type f -name anothadev.omachord | wc -l)
assert_eq "$hook_count" 0 "failed Connect left hook wrappers"
rm -f "$connect_result" "$TEST_ROOT/connect.stderr" "$blocked_parent"

blocked_parent="$TEST_ROOT/blocked-icon-parent"
printf '%s\n' blocked >"$blocked_parent"
connect_result=$(mktemp)
if OMACHORD_ICON_FILE="$blocked_parent/anothadev.omachord.svg" "$RUNNER" connect >"$connect_result" 2>"$TEST_ROOT/connect.stderr"; then
  fail "mid-Connect icon write failure should fail"
fi
assert_eq "$(jq -r '.code' "$connect_result")" connect-rolled-back "application-icon failure was not rolled back"
assert_missing "$XDG_DATA_HOME/applications/anothadev.omachord.desktop" "application-icon failure left a desktop entry"
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "application-icon failure left generated Lua"
assert_missing "$XDG_STATE_HOME/omarchy/omachord/connection.json" "application-icon failure left ownership state"
rm -f "$connect_result" "$TEST_ROOT/connect.stderr" "$blocked_parent"

"$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
printf '%s\n' 'BROKEN OMA LUA' >"$HYPR_CONFIG_DIR/omachord.lua"
printf '%s\n' tampered >"$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord"
printf '%s\n' tampered >"$ICON_FILE"
chmod +x "$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord"
"$RUNNER" status | jq -e '(.integrationComplete | not) and .ownedConnection' >/dev/null
"$RUNNER" connect | jq -e '.ok and .connected and .repaired' >/dev/null
luac -p "$HYPR_CONFIG_DIR/omachord.lua" || fail "repair left invalid generated Lua"
assert_file_contains "$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord" 'trigger hook theme-set'
cmp -s "$ICON_FILE" "$ROOT/assets/omachord-icon.svg" || fail "Repair did not restore the application icon"
rm -f "$HYPR_CONFIG_DIR/omachord.lua" "$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord"
"$RUNNER" connect | jq -e '.ok and .connected and .repaired' >/dev/null
[[ -f $HYPR_CONFIG_DIR/omachord.lua && -x $HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord ]] \
  || fail "Connect did not repair owned integration"
chmod 666 "$HYPR_CONFIG_DIR/omachord.lua" "$XDG_STATE_HOME/omarchy/omachord/connection.json"
chmod 666 "$CONFIG_PATH" "$XDG_DATA_HOME/applications/anothadev.omachord.desktop" "$ICON_FILE"
chmod 777 "$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord"
"$RUNNER" status | jq -e '(.integrationComplete | not) and (.configValid | not) and .ownedConnection' >/dev/null
if "$RUNNER" connect >/dev/null; then
  fail "Repair trusted an externally writable configuration"
fi
assert_eq "$(stat -c %a "$CONFIG_PATH")" 666 "rejected Repair changed configuration permissions"
chmod 600 "$CONFIG_PATH"
"$RUNNER" connect | jq -e '.ok and .connected and .repaired' >/dev/null
assert_eq "$(stat -c %a "$HYPR_CONFIG_DIR/omachord.lua")" 600 "repair left generated Lua writable"
assert_eq "$(stat -c %a "$XDG_STATE_HOME/omarchy/omachord/connection.json")" 600 "repair left ownership state writable"
assert_eq "$(stat -c %a "$CONFIG_PATH")" 600 "repair left canonical configuration writable"
assert_eq "$(stat -c %a "$XDG_DATA_HOME/applications/anothadev.omachord.desktop")" 644 "repair left desktop entry writable"
assert_eq "$(stat -c %a "$ICON_FILE")" 644 "repair left application icon writable"
assert_eq "$(stat -c %a "$HOOK_CONFIG_DIR/theme-set.d/anothadev.omachord")" 755 "repair left hook wrapper writable"
pass "managed integration permissions"

rm -f "$TEST_ROOT/generated-removal-window" "$TEST_ROOT/release-generated-removal"
env OMACHORD_FS_TEST_MATCH="$HYPR_CONFIG_DIR/omachord.lua" \
  OMACHORD_FS_TEST_PAUSE=after-exchange \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/generated-removal-window" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/release-generated-removal" \
  "$RUNNER" disconnect >"$TEST_ROOT/interrupted-disconnect-result" &
disconnect_pid=$!
for _ in {1..500}; do
  [[ ! -f $TEST_ROOT/generated-removal-window ]] || break
  sleep 0.01
done
[[ -f $TEST_ROOT/generated-removal-window ]] || fail "Disconnect did not reach the atomic removal window"
kill -TERM "$disconnect_pid"
touch "$TEST_ROOT/release-generated-removal"
wait "$disconnect_pid" 2>/dev/null || true
"$RUNNER" status | jq -e '.connected and .ownedConnection and .integrationComplete' >/dev/null
if find "$HYPR_CONFIG_DIR" -maxdepth 1 -type f \
  \( -name '.omachord-remove.*' -o -name '.omachord-unlink.*' \) -print -quit | grep -q .; then
  fail "interrupted removal stranded a transaction inode"
fi
rm -f "$TEST_ROOT/generated-removal-window" "$TEST_ROOT/release-generated-removal" \
  "$TEST_ROOT/interrupted-disconnect-result"
pass "atomic removal signal deferral"

rm -f "$TEST_ROOT/generated-remove-race-ready" "$TEST_ROOT/generated-remove-race-release"
disconnect_result=$(mktemp)
env OMACHORD_FS_TEST_MATCH="$HYPR_CONFIG_DIR/omachord.lua" \
  OMACHORD_FS_TEST_PAUSE=after-exchange \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/generated-remove-race-ready" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/generated-remove-race-release" \
  "$RUNNER" disconnect >"$disconnect_result" &
disconnect_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/generated-remove-race-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/generated-remove-race-ready ]] || fail "generated removal did not reach its race window"
printf '%s\n' 'concurrently edited generated file' >"$HYPR_CONFIG_DIR/omachord.lua.concurrent"
mv -fT -- "$HYPR_CONFIG_DIR/omachord.lua.concurrent" "$HYPR_CONFIG_DIR/omachord.lua"
touch "$TEST_ROOT/generated-remove-race-release"
if wait "$disconnect_pid"; then fail "Disconnect removed a generated file edited at atomic removal"; fi
assert_eq "$(jq -r '.code' "$disconnect_result")" rollback-failed "concurrent removal edit was incorrectly reported as rolled back"
assert_eq "$(cat "$HYPR_CONFIG_DIR/omachord.lua")" 'concurrently edited generated file' "atomic removal lost a concurrent generated-file edit"
"$RUNNER" status | jq -e '.connected and .ownedConnection and (.integrationComplete | not)' >/dev/null
rm -f "$disconnect_result" "$TEST_ROOT/generated-remove-race-ready" \
  "$TEST_ROOT/generated-remove-race-release"
"$RUNNER" connect | jq -e '.ok and .connected and .repaired' >/dev/null
luac -p "$HYPR_CONFIG_DIR/omachord.lua" || fail "repair after removal collision left invalid Lua"
pass "atomic removal collision"

printf '%s\n' 'BROKEN OMA LUA' >"$HYPR_CONFIG_DIR/omachord.lua"
rm -f "$HYPR_CONFIG_DIR/bindings.lua"
"$RUNNER" disconnect | jq -e '.ok and (.connected | not)' >/dev/null
assert_missing "$HYPR_CONFIG_DIR/omachord.lua" "stale-state Disconnect left generated Lua"
pass "partial Connect rollback and owned content repair"

printf '%s\n' 'SUPER + M -> Omachord: Personal binding' >"$TEST_ROOT/bindings.txt"
PERSONAL_CONFLICT=$(jq -c '.routines[0].triggers[0].override = false' <<<"$CONFIG")
if apply_config "$PERSONAL_CONFLICT" >/dev/null; then
  fail "an unrelated Oma-prefixed binding bypassed conflict protection"
fi
pass "exact managed-binding ownership"

printf '%s\n' 'SUPER SHIFT CTRL + SPACE -> Theme menu' >"$TEST_ROOT/bindings.txt"
normalized_binding=$($RUNNER bindings | jq -r '.[0].keys')
assert_eq "$normalized_binding" 'SUPER + SHIFT + CTRL + SPACE' "Omarchy modifier bundles were not normalized"
BUNDLED_CONFLICT=$(jq -c '.routines[0].triggers[0].keys = "SUPER + SHIFT + CTRL + SPACE"' <<<"$CONFIG")
if apply_config "$BUNDLED_CONFLICT" >/dev/null; then
  fail "normalized multi-modifier conflict should be rejected"
fi
pass "Omarchy modifier-bundle normalization"

printf '%s\n' 'SUPER + LEFT MOUSE BUTTON -> Move window' >"$TEST_ROOT/bindings.txt"
"$RUNNER" bindings | jq -e '.[0].keys == "SUPER + LEFT MOUSE BUTTON" and (.[0].editable | not)' >/dev/null
pass "non-editable pointer binding catalogue"

printf '%s\n' 'SUPER + M -> Existing microphone action' >"$TEST_ROOT/bindings.txt"
NO_OVERRIDE=$(jq -c '.routines[0].triggers[0].override = false' <<<"$CONFIG")
if apply_config "$NO_OVERRIDE" >/dev/null; then
  fail "occupied shortcut without override should be rejected"
fi
WITH_OVERRIDE=$(jq -c '.routines[0].triggers[0].override = true' <<<"$CONFIG")
apply_config "$WITH_OVERRIDE" | jq -e '.ok' >/dev/null
pass "explicit persistent shortcut override"

: >"$TEST_ROOT/bindings.txt"
directory_revision=$(config_revision)
mv "$CONFIG_PATH" "$CONFIG_PATH.saved"
mkdir "$CONFIG_PATH"
apply_result=$(mktemp)
if apply_config "$EMPTY" "$directory_revision" >"$apply_result"; then
  fail "a directory at the config path should fail atomically"
fi
[[ -d $CONFIG_PATH ]] || fail "failed atomic write replaced the destination directory"
[[ -z $(find "$CONFIG_PATH" -mindepth 1 -print -quit) ]] || fail "failed atomic write moved a temporary file into the destination directory"
rmdir "$CONFIG_PATH"
mv "$CONFIG_PATH.saved" "$CONFIG_PATH"
rm -f "$apply_result"
pass "non-regular config destination rejection"

printf '%s\n' 'this row has no separator' >"$TEST_ROOT/bindings.txt"
if "$RUNNER" bindings >/dev/null; then
  fail "unknown keybinding output should fail closed"
fi
pass "keybinding parser fails closed"

saved_config=$(cat "$CONFIG_PATH")
saved_revision=$(config_revision)
printf '%s\n' '{not-json' >"$CONFIG_PATH"
hook_result=$(mktemp)
if "$RUNNER" trigger hook post-boot >"$hook_result"; then
  fail "malformed hook configuration should fail"
fi
assert_eq "$(jq -r '.code' "$hook_result")" invalid-config "malformed hook config was not reported"
printf '%s\n' "$saved_config" >"$CONFIG_PATH"
rm -f "$hook_result"
pass "malformed hook configuration rejection"

: >"$TEST_ROOT/bindings.txt"
: >"$TEST_ROOT/shell.log"
rm -rf "$TEST_ROOT/shell-state"
printf '%s\n' Gruvbox >"$TEST_ROOT/theme.name"
printf '%s\n' 80 >"$TEST_ROOT/brightness"
ACTIVE_DIR="$XDG_STATE_HOME/omarchy/omachord/active"

reject_config() {
  if printf '%s\n' "$1" | "$RUNNER" config validate >/dev/null; then
    fail "$2"
  fi
}

stateful_routine() {
  jq -cn --arg id "$1" --argjson conditions "${2:-[]}" --argjson actions "$3" \
    '{id:$id,name:$id,enabled:true,triggers:[],conditions:$conditions,actions:$actions}'
}

STATEFUL=$(jq -cn '{
  version: 1,
  routines: [
    {
      id: "focus", name: "Focus", enabled: true,
      triggers: [{type:"hook",event:"post-boot"}],
      actions: [
        {type:"dnd",value:true,restore:true},
        {type:"nightlight",value:true,restore:true},
        {type:"stay-awake",value:true,restore:true},
        {type:"theme",value:"tokyo-night",restore:true},
        {type:"brightness",value:40,restore:true},
        {type:"exec",program:"capture-args",args:["focus-on"]}
      ],
      onEnd: {mode:"restore",actions:[]},
      keepUntil: "conditions"
    },
    {
      id: "failing-activation", name: "Failing activation", enabled: true, triggers: [],
      actions: [
        {type:"dnd",value:true,restore:true},
        {type:"brightness",value:10,restore:true},
        {type:"exec",program:"always-fail",args:[]}
      ]
    },
    {
      id: "interrupted-activation", name: "Interrupted activation", enabled: true, triggers: [],
      actions: [{type:"dnd",value:true,restore:true}]
    },
    {
      id: "failing-end-action", name: "Failing end action", enabled: true, triggers: [],
      actions: [{type:"nightlight",value:true,restore:true}],
      onEnd: {mode:"actions",actions:[
        {type:"exec",program:"counting-fail",args:[]},
        {type:"exec",program:"capture-args",args:["after-failure"]}
      ]}
    },
    {
      id: "end-actions", name: "End actions", enabled: true, triggers: [],
      actions: [{type:"nightlight",value:true,restore:true}],
      onEnd: {mode:"actions",actions:[
        {type:"exec",program:"capture-args",args:["ended"]},
        {type:"dnd",value:false,restore:false}
      ]}
    },
    {
      id: "leave-it", name: "Leave it", enabled: true, triggers: [],
      actions: [{type:"nightlight",value:true,restore:true}],
      onEnd: {mode:"none",actions:[]}
    },
    {
      id: "timed", name: "Timed", enabled: true, triggers: [],
      actions: [{type:"dnd",value:true,restore:false}],
      keepUntil: {minutes:30}
    },
    {
      id: "themed-hook", name: "Themed hook", enabled: false,
      triggers: [{type:"hook",event:"theme-set"}],
      actions: [
        {type:"theme",value:"catppuccin",restore:true},
        {type:"exec",program:"capture-hook",args:[]}
      ]
    },
    {
      id: "legacy", name: "Legacy", enabled: true, triggers: [],
      actions: [{type:"delay",milliseconds:0}]
    },
    {
      id: "conditional", name: "Conditional", enabled: true, triggers: [],
      conditions: [
        {type:"time",start:"18:30",end:"08:00",weekdays:[]},
        {type:"time",start:"09:00",end:"17:00",weekdays:["mon","tue","wed","thu","fri"]},
        {type:"wifi",ssids:["Office","Office-5G"]},
        {type:"power",source:"battery",batteryBelow:30},
        {type:"power",source:"ac",batteryBelow:0},
        {type:"omarchy-toggle",flag:"suspend-off"}
      ],
      actions: [{type:"nightlight",value:true,restore:true}]
    }
  ]
}')

printf '%s\n' "$STATEFUL" | "$RUNNER" config validate | jq -e '.ok' >/dev/null
reject_config "$(jq -c '.routines[0].actions[0].restore = "yes"' <<<"$STATEFUL")" "non-boolean restore should be rejected"
reject_config "$(jq -c 'del(.routines[0].actions[0].restore)' <<<"$STATEFUL")" "setter without restore should be rejected"
reject_config "$(jq -c '.routines[0].actions[3].value = "Tokyo Night"' <<<"$STATEFUL")" "theme names must be slugs"
reject_config "$(jq -c '.routines[0].actions[4].value = 101' <<<"$STATEFUL")" "brightness above 100 should be rejected"
reject_config "$(jq -c '.routines[0].actions[4].value = 40.5' <<<"$STATEFUL")" "fractional brightness should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[0].start = "25:00"' <<<"$STATEFUL")" "invalid HH:MM should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[0].end = "18:30"' <<<"$STATEFUL")" "empty time window should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[1].weekdays = ["mon","mon"]' <<<"$STATEFUL")" "duplicate weekdays should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[1].weekdays = ["monday"]' <<<"$STATEFUL")" "unknown weekday should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions = [range(17) | {type:"omarchy-toggle",flag:"f\(.)"}]' <<<"$STATEFUL")" "17 conditions should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[2].ssids = []' <<<"$STATEFUL")" "empty SSID list should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[2].ssids = ["'"$(printf 'x%.0s' {1..33})"'"]' <<<"$STATEFUL")" "33-byte SSID should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[2].ssids = [range(17) | "net\(.)"]' <<<"$STATEFUL")" "17 SSIDs should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[4].batteryBelow = 10' <<<"$STATEFUL")" "battery threshold with ac source should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[5].flag = "a/b"' <<<"$STATEFUL")" "flag with a slash should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[5].flag = "a..b"' <<<"$STATEFUL")" "flag with dot-dot should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "conditional")).conditions[5].type = "moon-phase"' <<<"$STATEFUL")" "unknown condition type should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "timed")).keepUntil.minutes = 0' <<<"$STATEFUL")" "zero keep-until minutes should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "timed")).keepUntil.minutes = 1441' <<<"$STATEFUL")" "keep-until beyond a day should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "timed")).keepUntil = "forever"' <<<"$STATEFUL")" "unknown keep-until should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "end-actions")).onEnd.actions[1].restore = true' <<<"$STATEFUL")" "restoring setters inside end actions should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "end-actions")).onEnd.mode = "restore"' <<<"$STATEFUL")" "end actions without the actions mode should be rejected"
reject_config "$(jq -c '(.routines[] | select(.id == "end-actions")).onEnd.mode = "later"' <<<"$STATEFUL")" "unknown end mode should be rejected"
apply_config "$STATEFUL" | jq -e '.ok and .deactivated == []' >/dev/null
"$RUNNER" config show | jq -e '.routines[] | select(.id == "legacy") | (has("conditions") or has("onEnd") or has("keepUntil")) | not' >/dev/null
pass "condition and setter schema validation"

activate_result=$(mktemp)
"$RUNNER" activate focus test >"$activate_result" || fail "activation failed: $(cat "$activate_result")"
jq -e '.ok and .state == "activated" and .expiresAt == null' "$activate_result" >/dev/null
assert_eq "$(stat -c %a "$ACTIVE_DIR")" 700 "activation directory is not private"
assert_eq "$(stat -c %a "$ACTIVE_DIR/focus.json")" 600 "activation snapshot is not private"
jq -e '.version == 1 and .routineId == "focus" and .trigger == "test" and .onEndMode == "restore"
  and (.claims == ["brightness","dnd","nightlight","stay-awake","theme"])
  and (.setters | length == 5)
  and (.setters[0] | .type == "dnd" and .before == false and .applied == true)
  and (.setters[2] | .type == "stay-awake" and .before == false and .applied == true)
  and (.setters[3] | .type == "theme" and .before == "gruvbox" and .applied == "tokyo-night")
  and (.setters[4] | .type == "brightness" and .before == 80 and .applied == 40)' "$ACTIVE_DIR/focus.json" >/dev/null
[[ -f $TEST_ROOT/shell-state/dnd && -f $TEST_ROOT/shell-state/nightlight && -f $TEST_ROOT/shell-state/stay-awake ]] \
  || fail "setters were not applied through the shell"
assert_eq "$(cat "$TEST_ROOT/theme.name")" "Tokyo Night" "theme setter was not applied"
assert_eq "$(cat "$TEST_ROOT/brightness")" 40 "brightness setter was not applied"
assert_eq "$(cat "$TEST_ROOT/captured.args")" focus-on "ordinary actions did not run during activation"
"$RUNNER" active | jq -e 'length == 1 and .[0].routineId == "focus" and .[0].setterCount == 5 and .[0].trigger == "test"' >/dev/null
"$RUNNER" status | jq -e '.activeCount == 1' >/dev/null
"$RUNNER" logs 1 | jq -e '.[0].routineId == "focus" and .[0].status == "activated" and .[0].trigger == "test"' >/dev/null
pass "setter activation snapshot"

setter_conflict=$(mktemp)
if "$RUNNER" activate interrupted-activation test >"$setter_conflict"; then
  fail "two active routines should not own the same restoring setter"
fi
jq -e '.code == "setter-conflict" and (.error | test("dnd.*focus"))' "$setter_conflict" >/dev/null
assert_missing "$ACTIVE_DIR/interrupted-activation.json" "setter conflict left a second activation snapshot"
rm -f "$setter_conflict"
pass "exclusive restoring-setter ownership"

shell_calls=$(wc -l <"$TEST_ROOT/shell.log")
log_entries=$($RUNNER logs 100 | jq 'length')
"$RUNNER" activate focus test | jq -e '.ok and .alreadyActive == true' >/dev/null
assert_eq "$(wc -l <"$TEST_ROOT/shell.log")" "$shell_calls" "repeated activation touched the shell"
assert_eq "$($RUNNER logs 100 | jq 'length')" "$log_entries" "repeated activation was logged"
pass "activate idempotency"

: >"$TEST_ROOT/shell.log"
"$RUNNER" deactivate focus test | jq -e '.ok and .state == "deactivated" and .restored == 5 and .skipped == 0' >/dev/null
[[ ! -f $TEST_ROOT/shell-state/dnd && ! -f $TEST_ROOT/shell-state/nightlight && ! -f $TEST_ROOT/shell-state/stay-awake ]] \
  || fail "shell setters were not restored"
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "theme was not restored"
assert_eq "$(cat "$TEST_ROOT/brightness")" 80 "brightness was not restored"
assert_missing "$ACTIVE_DIR/focus.json" "snapshot survived deactivation"
"$RUNNER" active | jq -e 'length == 0' >/dev/null
awake_line=$(grep -n '^idle enable$' "$TEST_ROOT/shell.log" | cut -d: -f1)
night_line=$(grep -n '^nightlight disable$' "$TEST_ROOT/shell.log" | cut -d: -f1)
dnd_line=$(grep -n '^notifications setDnd off$' "$TEST_ROOT/shell.log" | cut -d: -f1)
((awake_line < night_line && night_line < dnd_line)) || fail "setters were not restored in reverse order"
"$RUNNER" logs 1 | jq -e '.[0].routineId == "focus" and .[0].status == "deactivated"' >/dev/null
pass "restore round trip"

"$RUNNER" activate focus test | jq -e '.ok and .state == "activated"' >/dev/null
printf '%s\n' 55 >"$TEST_ROOT/brightness"
"$RUNNER" deactivate focus test | jq -e '.ok and .restored == 4 and .skipped == 1' >/dev/null
assert_eq "$(cat "$TEST_ROOT/brightness")" 55 "a value changed by the user was overwritten on restore"
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "other setters were not restored"
printf '%s\n' 80 >"$TEST_ROOT/brightness"
pass "compare-before-restore"

log_entries=$($RUNNER logs 100 | jq 'length')
"$RUNNER" deactivate focus test | jq -e '.ok and .alreadyInactive == true' >/dev/null
assert_eq "$($RUNNER logs 100 | jq 'length')" "$log_entries" "inactive deactivation was logged"
pass "deactivate without snapshot"

"$RUNNER" run focus test | jq -e '.ok and .state == "activated"' >/dev/null
"$RUNNER" run focus test | jq -e '.ok and .state == "deactivated"' >/dev/null
"$RUNNER" run legacy test | jq -e '.ok and (has("state") | not)' >/dev/null
"$RUNNER" trigger hook post-boot | jq -e '.ok and .matched == 1' >/dev/null
"$RUNNER" active | jq -e 'length == 1 and .[0].trigger == "hook:post-boot"' >/dev/null
"$RUNNER" trigger hook post-boot | jq -e '.ok and .matched == 1' >/dev/null
"$RUNNER" active | jq -e 'length == 1' >/dev/null
assert_eq "$($RUNNER logs 100 | jq '[.[] | select(.trigger == "hook:post-boot" and .status == "activated")] | length')" 1 \
  "a repeated event re-activated an active routine"
"$RUNNER" deactivate focus test | jq -e '.ok and .state == "deactivated"' >/dev/null
pass "manual toggle semantics"

failure_result=$(mktemp)
if "$RUNNER" run failing-activation test >"$failure_result"; then
  fail "a failing activation should fail"
fi
jq -e '.code == "action-failed" and (.error | startswith("activate: "))' "$failure_result" >/dev/null
assert_missing "$TEST_ROOT/shell-state/dnd" "failed activation left do-not-disturb on"
assert_eq "$(cat "$TEST_ROOT/brightness")" 80 "failed activation left brightness changed"
assert_missing "$ACTIVE_DIR/failing-activation.json" "failed activation left a snapshot"
"$RUNNER" logs 1 | jq -e '.[0].routineId == "failing-activation" and .[0].status == "failed"' >/dev/null
rm -f "$failure_result"
pass "activation failure rollback"

touch "$TEST_ROOT/fail-after-dnd-set"
if "$RUNNER" activate interrupted-activation test >"$failure_result"; then
  fail "a setter that failed after its side effect should fail activation"
fi
assert_missing "$TEST_ROOT/shell-state/dnd" "write-ahead rollback left do-not-disturb changed"
assert_missing "$ACTIVE_DIR/interrupted-activation.json" "completed write-ahead rollback kept a snapshot"

touch "$TEST_ROOT/hold-after-dnd-set"
"$RUNNER" activate interrupted-activation test >"$TEST_ROOT/interrupted-result" &
interrupted_pid=$!
for _ in {1..500}; do
  [[ -f $TEST_ROOT/dnd-set ]] && break
  kill -0 "$interrupted_pid" 2>/dev/null || break
  sleep 0.01
done
[[ -f $TEST_ROOT/dnd-set ]] || fail "interrupted setter did not reach its side effect"
jq -e '.setters | length == 1 and .[0].type == "dnd" and .[0].before == false and .[0].applied == true' \
  "$ACTIVE_DIR/interrupted-activation.json" >/dev/null \
  || fail "setter recovery entry was not durable before the side effect completed"
kill -KILL "$interrupted_pid" 2>/dev/null || true
wait "$interrupted_pid" 2>/dev/null || true
rm -f "$TEST_ROOT/hold-after-dnd-set" "$TEST_ROOT/dnd-set"
"$RUNNER" deactivate interrupted-activation test | jq -e '.ok and .restored == 1' >/dev/null
assert_missing "$TEST_ROOT/shell-state/dnd" "interrupted setter was not restored from its journal"
rm -f "$failure_result" "$TEST_ROOT/interrupted-result"
pass "write-ahead setter recovery"

printf '%s\n' 'Gruvbox<script>' >"$TEST_ROOT/theme.name"
if "$RUNNER" activate focus test >"$activate_result"; then
  fail "a malformed current theme should refuse activation"
fi
jq -e '.code == "action-failed" and (.error | test("theme"))' "$activate_result" >/dev/null
assert_missing "$TEST_ROOT/shell-state/dnd" "malformed theme output left earlier setters applied"
assert_missing "$ACTIVE_DIR/focus.json" "malformed theme output left a snapshot"
printf '%s\n' Gruvbox >"$TEST_ROOT/theme.name"

touch "$TEST_ROOT/brightness-garbage"
if "$RUNNER" activate focus test >"$activate_result"; then
  fail "an unreadable setter should refuse activation"
fi
jq -e '.code == "action-failed" and (.error | test("brightness"))' "$activate_result" >/dev/null
assert_missing "$TEST_ROOT/shell-state/dnd" "unreadable setter left earlier setters applied"
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "unreadable setter left the theme changed"
assert_missing "$ACTIVE_DIR/focus.json" "unreadable setter left a snapshot"
rm -f "$TEST_ROOT/brightness-garbage"
touch "$TEST_ROOT/shell-down"
if "$RUNNER" activate focus test >"$activate_result"; then
  fail "a stopped shell should refuse activation"
fi
jq -e '.code == "action-failed"' "$activate_result" >/dev/null
assert_missing "$ACTIVE_DIR/focus.json" "stopped shell left a snapshot"
rm -f "$TEST_ROOT/shell-down" "$activate_result"
pass "fail-closed setter reads"

"$RUNNER" run leave-it test | jq -e '.state == "activated"' >/dev/null
"$RUNNER" run leave-it test | jq -e '.state == "deactivated" and .restored == 0' >/dev/null
[[ -f $TEST_ROOT/shell-state/nightlight ]] || fail "end mode none restored the night light"
rm -f "$TEST_ROOT/shell-state/nightlight"
"$RUNNER" run end-actions test | jq -e '.state == "activated"' >/dev/null
touch "$TEST_ROOT/shell-state/dnd"
"$RUNNER" run end-actions test | jq -e '.state == "deactivated" and .restored == 1' >/dev/null
assert_missing "$TEST_ROOT/shell-state/nightlight" "end actions mode did not restore first"
assert_eq "$(cat "$TEST_ROOT/captured.args")" ended "end actions did not run"
assert_missing "$TEST_ROOT/shell-state/dnd" "end action setter did not run"
pass "end modes"

"$RUNNER" run end-actions test | jq -e '.state == "activated"' >/dev/null
end_commit="$XDG_STATE_HOME/omarchy/omachord/config.commit.json"
saved_end_commit=$(cat "$end_commit")
rm -f "$end_commit"
end_failure=$(mktemp)
if "$RUNNER" deactivate end-actions test >"$end_failure"; then
  fail "end actions without a committed routine should retain recovery state"
fi
jq -e '.code == "action-failed" and (.error | test("end action:.*recovery record kept"))' "$end_failure" >/dev/null
[[ -f $ACTIVE_DIR/end-actions.json ]] || fail "unavailable end actions discarded their snapshot"
printf '%s\n' "$saved_end_commit" >"$end_commit"
chmod 600 "$end_commit"
"$RUNNER" deactivate end-actions test | jq -e '.ok and .state == "deactivated"' >/dev/null
assert_eq "$(cat "$TEST_ROOT/captured.args")" ended "retried end actions did not run"
rm -f "$end_failure"
pass "end actions retain recovery state"

end_runs_before=$(grep -Fxc '<ended>' "$TEST_ROOT/capture-history" 2>/dev/null || printf 0)
"$RUNNER" run end-actions test | jq -e '.state == "activated"' >/dev/null
end_failure=$(mktemp)
if OMACHORD_FS_TEST_MATCH="$ACTIVE_DIR/end-actions.json" OMACHORD_FS_TEST_FAIL_REMOVE=1 \
    "$RUNNER" deactivate end-actions test >"$end_failure"; then
  fail "end-action snapshot removal failure should be reported"
fi
jq -e '.code == "action-failed" and (.error | test("Could not remove.*recovery record kept"))' "$end_failure" >/dev/null
"$RUNNER" deactivate end-actions test | jq -e '.ok and .state == "deactivated"' >/dev/null
end_runs_after=$(grep -Fxc '<ended>' "$TEST_ROOT/capture-history")
assert_eq "$end_runs_after" "$((end_runs_before + 1))" "completed end actions repeated while retrying snapshot removal"
rm -f "$end_failure"
pass "end-action progress survives retry"

"$RUNNER" run failing-end-action test | jq -e '.state == "activated"' >/dev/null
end_failure=$(mktemp)
if "$RUNNER" deactivate failing-end-action test >"$end_failure"; then
  fail "a failing end action should fail deactivation"
fi
jq -e '.code == "action-failed"' "$end_failure" >/dev/null
jq -e '.endActionIndex == 1' "$ACTIVE_DIR/failing-end-action.json" >/dev/null
"$RUNNER" deactivate failing-end-action test | jq -e '.ok and .state == "deactivated"' >/dev/null
assert_eq "$(cat "$TEST_ROOT/counting-fail.count")" 1 "a failed end action repeated on retry"
assert_eq "$(cat "$TEST_ROOT/captured.args")" after-failure "retry did not continue with the next end action"
rm -f "$end_failure"
pass "failed end actions are at-most-once"

before_epoch=$(date +%s)
"$RUNNER" run timed test | jq -e '.state == "activated" and (.expiresAt | type == "string")' >/dev/null
expires_epoch=$(date -d "$(jq -r '.expiresAt' "$ACTIVE_DIR/timed.json")" +%s)
((expires_epoch >= before_epoch + 1740 && expires_epoch <= before_epoch + 1860)) \
  || fail "keep-until expiry was not recorded 30 minutes ahead"
"$RUNNER" active | jq -e '.[0].keepUntil.minutes == 30' >/dev/null
"$RUNNER" run timed test | jq -e '.state == "deactivated" and .restored == 0' >/dev/null
[[ -f $TEST_ROOT/shell-state/dnd ]] || fail "a setter without restore was reverted"
rm -f "$TEST_ROOT/shell-state/dnd"
pass "keep-until expiry recorded"

if ! "$RUNNER" status | jq -e '.connected' >/dev/null; then
  "$RUNNER" connect "$(config_revision)" | jq -e '.ok and .connected' >/dev/null
fi
service_revision=$(config_revision)
"$RUNNER" activate interrupted-activation condition "$service_revision" \
  | jq -e '.ok and .state == "activated" and .trigger == "condition"' >/dev/null
"$RUNNER" deactivate interrupted-activation condition "$service_revision" \
  | jq -e '.ok and .state == "deactivated"' >/dev/null

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
stale_transition=$(mktemp)
if "$RUNNER" deactivate focus condition "$service_revision" >"$stale_transition"; then
  fail "a condition job should not deactivate a manually owned snapshot"
fi
jq -e '.code == "stale-transition"' "$stale_transition" >/dev/null
[[ -f $ACTIVE_DIR/focus.json ]] || fail "a stale condition deactivation removed the manual snapshot"
"$RUNNER" deactivate focus test | jq -e '.ok' >/dev/null

"$RUNNER" activate timed test | jq -e '.state == "activated"' >/dev/null
if "$RUNNER" deactivate timed timer "$service_revision" >"$stale_transition"; then
  fail "a timer job should not deactivate before its deadline"
fi
jq -e '.code == "stale-transition"' "$stale_transition" >/dev/null
"$RUNNER" deactivate timed test | jq -e '.ok' >/dev/null
rm -f "$TEST_ROOT/shell-state/dnd"

if "$RUNNER" activate interrupted-activation condition "sha256:$(printf '0%.0s' {1..64})" >"$stale_transition"; then
  fail "a stale service activation should not execute"
fi
jq -e '.code == "stale-config"' "$stale_transition" >/dev/null
assert_missing "$ACTIVE_DIR/interrupted-activation.json" "a stale service activation created a snapshot"
rm -f "$stale_transition"
pass "revision-bound service transitions"

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
apply_config "$(jq -c 'del(.routines[0])' <<<"$STATEFUL")" | jq -e '.ok and .deactivated == ["focus"]' >/dev/null
assert_eq "$(cat "$TEST_ROOT/brightness")" 80 "deleting an active routine did not restore its setters"
assert_missing "$ACTIVE_DIR/focus.json" "deleting an active routine left a snapshot"
apply_config "$STATEFUL" | jq -e '.ok and .deactivated == []' >/dev/null
"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
apply_config "$(jq -c '.routines[0].enabled = false' <<<"$STATEFUL")" | jq -e '.ok and .deactivated == ["focus"]' >/dev/null
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "disabling an active routine did not restore its setters"
apply_config "$STATEFUL" | jq -e '.ok' >/dev/null
if ! "$RUNNER" status | jq -e '.connected' >/dev/null; then
  "$RUNNER" connect "$(config_revision)" | jq -e '.ok and .connected' >/dev/null
fi
"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
"$RUNNER" disconnect | jq -e '.ok and (.connected | not) and .deactivated == ["focus"]' >/dev/null
assert_missing "$ACTIVE_DIR/focus.json" "disconnect left an active routine"
assert_missing "$TEST_ROOT/shell-state/nightlight" "disconnect did not restore setters"
"$RUNNER" connect "$(config_revision)" | jq -e '.ok and .connected' >/dev/null
pass "orphan deactivation on apply and disconnect"

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
before_failed_apply=$(cat "$CONFIG_PATH")
before_failed_revision=$(config_revision)
touch "$TEST_ROOT/shell-down"
failed_cleanup=$(mktemp)
if apply_config "$(jq -c 'del(.routines[0])' <<<"$STATEFUL")" >"$failed_cleanup"; then
  fail "an apply with a failed orphan restore should fail"
fi
jq -e '.code == "action-failed" and (.error | test("recovery record kept"))' "$failed_cleanup" >/dev/null
assert_eq "$(cat "$CONFIG_PATH")" "$before_failed_apply" "failed orphan cleanup published the candidate config"
assert_eq "$(config_revision)" "$before_failed_revision" "failed orphan cleanup changed the config revision"
[[ -f $ACTIVE_DIR/focus.json ]] || fail "failed orphan cleanup discarded its recovery record"
rm -f "$TEST_ROOT/shell-down" "$failed_cleanup"
touch "$TEST_ROOT/require-theme-hook-success"
start=$(date +%s%3N)
apply_config "$(jq -c 'del(.routines[0])' <<<"$STATEFUL")" | jq -e '.ok and .deactivated == ["focus"]' >/dev/null
elapsed=$(($(date +%s%3N) - start))
rm -f "$TEST_ROOT/require-theme-hook-success"
((elapsed < 10000)) || fail "orphan theme restore blocked on config-lock re-entry for ${elapsed}ms"
apply_config "$STATEFUL" | jq -e '.ok' >/dev/null
pass "failed orphan cleanup blocks config publication"

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
touch "$TEST_ROOT/shell-down"
failed_cleanup=$(mktemp)
if "$RUNNER" disconnect >"$failed_cleanup"; then
  fail "Disconnect with a failed restore should fail"
fi
jq -e '.code == "action-failed" and (.error | test("recovery record kept"))' "$failed_cleanup" >/dev/null
"$RUNNER" status | jq -e '.connected and .ownedConnection and .integrationComplete' >/dev/null
[[ -f $ACTIVE_DIR/focus.json ]] || fail "failed Disconnect discarded its recovery record"
rm -f "$TEST_ROOT/shell-down" "$failed_cleanup"
touch "$TEST_ROOT/require-theme-hook-success"
start=$(date +%s%3N)
"$RUNNER" disconnect | jq -e '.ok and (.connected | not) and .deactivated == ["focus"]' >/dev/null
elapsed=$(($(date +%s%3N) - start))
rm -f "$TEST_ROOT/require-theme-hook-success"
((elapsed < 10000)) || fail "Disconnect theme restore blocked on config-lock re-entry for ${elapsed}ms"
stale_transition=$(mktemp)
if "$RUNNER" activate interrupted-activation condition "$(config_revision)" >"$stale_transition"; then
  fail "a queued service activation should not run after Disconnect"
fi
jq -e '.code == "not-connected"' "$stale_transition" >/dev/null
assert_missing "$ACTIVE_DIR/interrupted-activation.json" "post-Disconnect activation created a snapshot"
rm -f "$stale_transition"
"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
"$RUNNER" disconnect | jq -e '.ok and .alreadyDisconnected and .deactivated == ["focus"]' >/dev/null
assert_missing "$ACTIVE_DIR/focus.json" "already-disconnected recovery left an active snapshot"
"$RUNNER" connect "$(config_revision)" | jq -e '.ok and .connected' >/dev/null
pass "Disconnect restore failure and disconnected recovery"

: >"$TEST_ROOT/theme-hook.log"
apply_config "$(jq -c '(.routines[] | select(.id == "themed-hook")).enabled = true' <<<"$STATEFUL")" | jq -e '.ok' >/dev/null
start=$(date +%s%3N)
"$RUNNER" run themed-hook test | jq -e '.state == "activated"' >/dev/null
elapsed=$(($(date +%s%3N) - start))
((elapsed < 10000)) || fail "theme re-entrancy took ${elapsed}ms"
assert_eq "$(cat "$TEST_ROOT/theme.name")" Catppuccin "theme setter did not apply"
assert_file_contains "$TEST_ROOT/theme-hook.log" hook-failed "nested theme-set hook did not report the busy routine"
mapfile -t hook_env <"$TEST_ROOT/hook.env"
assert_eq "${hook_env[0]}" test "activation did not export its trigger"
"$RUNNER" run themed-hook test | jq -e '.state == "deactivated" and .restored == 1' >/dev/null
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "theme was not restored"
apply_config "$STATEFUL" | jq -e '.ok and .deactivated == []' >/dev/null
pass "theme setter re-entrancy"

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
touch "$TEST_ROOT/shell-down"
failed_restore=$(mktemp)
if "$RUNNER" deactivate focus test >"$failed_restore"; then
  fail "a restore without the shell should fail"
fi
jq -e '.code == "action-failed" and (.error | test("recovery record kept"))' "$failed_restore" >/dev/null
[[ -f $ACTIVE_DIR/focus.json ]] || fail "a failed restore discarded the recovery record"
"$RUNNER" active | jq -e 'length == 1 and .[0].routineId == "focus"' >/dev/null
"$RUNNER" logs 1 | jq -e '.[0].status == "failed" and .[0].trigger == "test"' >/dev/null
rm -f "$TEST_ROOT/shell-down" "$failed_restore"
# The theme and brightness tools do not go through the shell, so the failed
# attempt already put those two back; the retry only touches what is left.
"$RUNNER" deactivate focus test | jq -e '.ok and .state == "deactivated" and .restored == 3 and .skipped == 2' >/dev/null
assert_missing "$ACTIVE_DIR/focus.json" "a completed restore kept its recovery record"
assert_eq "$(cat "$TEST_ROOT/theme.name")" Gruvbox "the theme was not restored across the retry"
[[ ! -f $TEST_ROOT/shell-state/dnd && ! -f $TEST_ROOT/shell-state/nightlight ]] || fail "the retry did not restore shell setters"
assert_eq "$(cat "$TEST_ROOT/brightness")" 80 "the retried restore did not finish"
pass "failed restore keeps the recovery record"

"$RUNNER" activate interrupted-activation test | jq -e '.state == "activated"' >/dev/null
snapshot_remove_failure=$(mktemp)
if OMACHORD_FS_TEST_MATCH="$ACTIVE_DIR/interrupted-activation.json" OMACHORD_FS_TEST_FAIL_REMOVE=1 \
    "$RUNNER" deactivate interrupted-activation test >"$snapshot_remove_failure"; then
  fail "deactivation should fail when its completed snapshot cannot be removed"
fi
jq -e '.code == "action-failed" and (.error | test("Could not remove.*recovery record kept"))' "$snapshot_remove_failure" >/dev/null
[[ -f $ACTIVE_DIR/interrupted-activation.json ]] || fail "failed snapshot removal lost the recovery record"
"$RUNNER" deactivate interrupted-activation test | jq -e '.ok and .skipped == 1' >/dev/null
rm -f "$snapshot_remove_failure"
pass "snapshot removal failure is propagated"

# An install connected before the commit record existed: every artifact is
# present but config.commit.json is not, so the panel cannot load the config
# and Repair is the only way out.
commit_file="$XDG_STATE_HOME/omarchy/omachord/config.commit.json"
saved_commit=$(cat "$commit_file")
rm -f "$commit_file"
"$RUNNER" status | jq -e '.connected and .ownedConnection and (.integrationComplete | not)' >/dev/null
"$RUNNER" config snapshot | jq -e '.ok and (.committed | not)' >/dev/null
legacy_revision=$(config_revision)
"$RUNNER" connect "$legacy_revision" | jq -e '.ok and .connected and .repaired and .revision == "'"$legacy_revision"'"' >/dev/null
[[ -f $commit_file ]] || fail "repairing a legacy install did not write the commit record"
"$RUNNER" status | jq -e '.integrationComplete' >/dev/null
"$RUNNER" config snapshot | jq -e '.ok and .committed' >/dev/null
assert_eq "$(cat "$commit_file")" "$saved_commit" "repair committed a different revision"
pass "legacy install repair commits the configuration"

"$RUNNER" activate focus test | jq -e '.state == "activated"' >/dev/null
cp -- "$ACTIVE_DIR/focus.json" "$TEST_ROOT/valid-focus-snapshot.json"
jq '.setters[0].before = "corrupt"' "$TEST_ROOT/valid-focus-snapshot.json" >"$ACTIVE_DIR/focus.json"
chmod 600 "$ACTIVE_DIR/focus.json"
invalid_result=$(mktemp)
if "$RUNNER" deactivate focus test >"$invalid_result"; then
  fail "a snapshot with an invalid setter value should fail closed"
fi
jq -e '.code == "unsafe-state"' "$invalid_result" >/dev/null
cp -- "$TEST_ROOT/valid-focus-snapshot.json" "$ACTIVE_DIR/focus.json"
chmod 600 "$ACTIVE_DIR/focus.json"
"$RUNNER" deactivate focus test | jq -e '.ok' >/dev/null
rm -f "$invalid_result" "$TEST_ROOT/valid-focus-snapshot.json"

"$RUNNER" activate timed test | jq -e '.state == "activated"' >/dev/null
cp -- "$ACTIVE_DIR/timed.json" "$TEST_ROOT/valid-timed-snapshot.json"
jq '.keepUntil = "conditions" | .expiresAt = "2000-01-01T00:00:00Z"' \
  "$TEST_ROOT/valid-timed-snapshot.json" >"$ACTIVE_DIR/timed.json"
chmod 600 "$ACTIVE_DIR/timed.json"
if "$RUNNER" deactivate timed timer "$(config_revision)" >"$invalid_result"; then
  fail "a timer should reject a snapshot without timer ownership"
fi
jq -e '.code == "unsafe-state"' "$invalid_result" >/dev/null
cp -- "$TEST_ROOT/valid-timed-snapshot.json" "$ACTIVE_DIR/timed.json"
chmod 600 "$ACTIVE_DIR/timed.json"
"$RUNNER" deactivate timed test | jq -e '.ok' >/dev/null
rm -f "$TEST_ROOT/shell-state/dnd" "$invalid_result" "$TEST_ROOT/valid-timed-snapshot.json"
pass "activation snapshot values and timer ownership"

printf '%s\n' '{"version":1,"routineId":"focus","setters":"nope"}' >"$ACTIVE_DIR/focus.json"
chmod 600 "$ACTIVE_DIR/focus.json"
for invalid_command in "active" "deactivate focus test" "run focus test" "activate focus test"; do
  invalid_result=$(mktemp)
  # shellcheck disable=SC2086
  if "$RUNNER" $invalid_command >"$invalid_result"; then
    fail "an invalid snapshot should fail closed: $invalid_command"
  fi
  assert_eq "$(jq -r '.code' "$invalid_result")" unsafe-state "invalid snapshot returned the wrong error for: $invalid_command"
  rm -f "$invalid_result"
done
[[ -f $ACTIVE_DIR/focus.json ]] || fail "an invalid snapshot was silently discarded"
rm -f "$ACTIVE_DIR/focus.json"
"$RUNNER" active | jq -e 'length == 0' >/dev/null
pass "invalid snapshot fails closed"

log_count=$($RUNNER logs 100 | jq 'length')
((log_count >= 6)) || fail "expected run history entries"
"$RUNNER" logs 08 | jq -e 'type == "array" and length <= 8' >/dev/null
pass "structured run history"

widget_result=$(mktemp)
widget_marker="$XDG_STATE_HOME/omarchy/omachord/bar-widget.json"
widget_backups="$XDG_STATE_HOME/omarchy/omachord/backups"
shell_config="$OMARCHY_CONFIG_DIR/shell.json"
shell_center='[{"id":"omarchy.indicators"},{"id":"omarchy.keyboard-layout"},{"id":"omarchy.weather"},{"id":"omarchy.clock"}]'
write_shell_config() {
  printf '%s\n' "$1" >"$shell_config"
  chmod "${2:-600}" "$shell_config"
}
shell_config_neither="{\"version\":1,\"bar\":{\"layout\":{\"left\":[{\"id\":\"omarchy.menu\"}],\"center\":$shell_center,\"right\":[]}},\"plugins\":[]}"
shell_config_plugins_only="{\"version\":1,\"bar\":{\"layout\":{\"left\":[{\"id\":\"omarchy.menu\"}],\"center\":$shell_center,\"right\":[]}},\"plugins\":[{\"id\":\"anothadev.omachord\"}]}"
shell_config_in_bar='{"version":1,"bar":{"layout":{"left":[],"center":[{"id":"omarchy.indicators"},{"id":"anothadev.omachord"},{"id":"omarchy.clock"}],"right":[]}},"plugins":[]}'

# A fresh install: the plugin is enabled nowhere, so the shell is asked.
write_shell_config "$shell_config_neither"
touch "$TEST_ROOT/shell-scanning"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must report a shell that is still scanning"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-not-ready "widget ensure returned the wrong error while scanning"
assert_missing "$widget_marker" "a refused placement must not be recorded"
rm -f "$TEST_ROOT/shell-scanning"
: >"$TEST_ROOT/widget.log"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must not trust an ok answer that left shell.json unchanged"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-refused "an unapplied ok answer returned the wrong error"
assert_missing "$widget_marker" "an unapplied placement must not be recorded"
assert_eq "$(cat "$TEST_ROOT/widget.log")" 'anothadev.omachord {"section":"center","after":"omarchy.indicators"}' "widget ensure sent the wrong placement"
assert_eq "$(jq -c '.bar.layout.center | map(.id)' "$shell_config")" '["omarchy.indicators","omarchy.keyboard-layout","omarchy.weather","omarchy.clock"]' \
  "the putBarWidget path must not edit shell.json itself"
: >"$TEST_ROOT/widget.log"
touch "$TEST_ROOT/shell-applies-widget"
"$RUNNER" widget ensure | jq -e '.ok and .placed == true and (.migrated | not)' >/dev/null
rm -f "$TEST_ROOT/shell-applies-widget"
assert_eq "$(cat "$TEST_ROOT/widget.log")" 'anothadev.omachord {"section":"center","after":"omarchy.indicators"}' "widget ensure sent the wrong placement"
assert_eq "$(stat -c %a "$widget_marker")" 600 "the widget record must be private"
assert_eq "$(jq -c '.bar.layout.center | map(.id)' "$shell_config")" '["omarchy.indicators","anothadev.omachord","omarchy.keyboard-layout","omarchy.weather","omarchy.clock"]' \
  "the shell stub did not place the widget where expected"
"$RUNNER" widget ensure | jq -e '.ok and .placed == false and .skipped == true' >/dev/null
assert_eq "$(wc -l <"$TEST_ROOT/widget.log")" 1 "a recorded placement must not ask the shell again"
"$RUNNER" widget status \
  | jq -e '.ok and .recorded == true and .placement.section == "center" and .inBar == true and .inPlugins == false' >/dev/null
"$RUNNER" widget forget | jq -e '.ok and .recorded == false' >/dev/null
assert_missing "$widget_marker" "forget must remove the widget record"
write_shell_config "$shell_config_neither"
touch "$TEST_ROOT/shell-down"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must fail when the shell is not running"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-unavailable "widget ensure returned the wrong error without a shell"
assert_missing "$widget_marker" "an unanswered placement must not be recorded"
rm -f "$TEST_ROOT/shell-down"

# Enabled after the widget existed: the id is already on the bar.
write_shell_config "$shell_config_in_bar"
: >"$TEST_ROOT/widget.log"
"$RUNNER" widget ensure | jq -e '.ok and .placed == false and .alreadyPresent == true' >/dev/null
assert_eq "$(stat -c %a "$widget_marker")" 600 "the widget record must be private"
assert_eq "$(wc -c <"$TEST_ROOT/widget.log")" 0 "a widget already on the bar must not involve the shell"
assert_eq "$(jq -c . "$shell_config")" "$shell_config_in_bar" "an already-present widget must leave shell.json alone"
"$RUNNER" widget status | jq -e '.ok and .recorded == true and .inBar == true and .inPlugins == false' >/dev/null
"$RUNNER" widget forget | jq -e '.ok and .recorded == false' >/dev/null

# Upgraded from 0.2.0: the id sits in plugins[], where putBarWidget answers ok
# without placing anything, so the runner moves it onto the bar itself.
write_shell_config "$shell_config_plugins_only"
: >"$TEST_ROOT/widget.log"
"$RUNNER" widget status | jq -e '.ok and .recorded == false and .inBar == false and .inPlugins == true' >/dev/null
"$RUNNER" widget ensure >"$widget_result" || fail "widget ensure must migrate a plugins[] entry"
jq -e '.ok and .placed == true and .migrated == true' "$widget_result" >/dev/null \
  || fail "widget ensure did not report the migration"
assert_eq "$(jq -c '.plugins' "$shell_config")" '[]' "the migrated id must leave plugins[]"
assert_eq "$(jq -c '.bar.layout.center | map(.id)' "$shell_config")" '["omarchy.indicators","anothadev.omachord","omarchy.keyboard-layout","omarchy.weather","omarchy.clock"]' \
  "the migrated widget must follow omarchy.indicators"
assert_eq "$(jq -c '[.version, (.bar.layout.left | map(.id)), .bar.layout.right]' "$shell_config")" '[1,["omarchy.menu"],[]]' \
  "the migration changed unrelated shell.json content"
assert_eq "$(stat -c %a "$shell_config")" 600 "the migration must preserve the shell.json mode"
widget_backup=$(jq -r '.backup' "$widget_result")
[[ $widget_backup == "$widget_backups"/shell.json.* ]] || fail "the migration backup was not recorded under the state backups: $widget_backup"
[[ -f $widget_backup ]] || fail "the migration must back up the previous shell.json"
assert_eq "$(stat -c %a "$widget_backup")" 600 "the shell.json backup must be private"
assert_eq "$(jq -c . "$widget_backup")" "$shell_config_plugins_only" "the shell.json backup must hold the previous content"
assert_eq "$(stat -c %a "$widget_marker")" 600 "the widget record must be private"
assert_eq "$(cat "$TEST_ROOT/widget.log")" reloadConfig "the migration must reload the shell config and never call putBarWidget"
"$RUNNER" widget status | jq -e '.ok and .recorded == true and .inBar == true and .inPlugins == false' >/dev/null
"$RUNNER" widget ensure | jq -e '.ok and .placed == false and .skipped == true' >/dev/null
"$RUNNER" widget forget | jq -e '.ok and .recorded == false' >/dev/null

shell_config_concurrent='{"version":1,"bar":{"layout":{"left":[],"center":[{"id":"omarchy.clock"}],"right":[]}},"plugins":[{"id":"anothadev.omachord"}],"concurrent":true}'
shell_config_disabled='{"version":1,"bar":{"layout":{"left":[],"center":[{"id":"omarchy.clock"}],"right":[]}},"plugins":[],"concurrent":"disabled"}'
write_shell_config "$shell_config_plugins_only"
printf '%s\n' "$shell_config_disabled" >"$TEST_ROOT/concurrent-shell-config.json"
touch "$TEST_ROOT/inject-shell-config-before-baseline"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget migration must not undo a concurrent removal before its baseline"
fi
assert_eq "$(jq -r '.code' "$widget_result")" unsafe-state "a pre-baseline shell.json edit returned the wrong error"
assert_eq "$(jq -c . "$shell_config")" "$shell_config_disabled" "widget migration undid a concurrent removal"
assert_missing "$widget_marker" "a rejected pre-baseline migration must not be recorded"
rm -f "$TEST_ROOT/concurrent-shell-config.json" "$TEST_ROOT/inject-shell-config-before-baseline"

write_shell_config "$shell_config_plugins_only"
printf '%s\n' "$shell_config_concurrent" >"$TEST_ROOT/concurrent-shell-config.json"
rm -f "$TEST_ROOT/shell-config-race-ready" "$TEST_ROOT/shell-config-race-release"
env OMACHORD_FS_TEST_MATCH="$shell_config" OMACHORD_FS_TEST_PAUSE=before-publish \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/shell-config-race-ready" \
  OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/shell-config-race-release" \
  "$RUNNER" widget ensure >"$widget_result" &
widget_pid=$!
for _ in {1..500}; do
  [[ -e $TEST_ROOT/shell-config-race-ready ]] && break
  sleep 0.01
done
[[ -e $TEST_ROOT/shell-config-race-ready ]] || fail "widget migration did not reach compare-and-swap"
cp -- "$TEST_ROOT/concurrent-shell-config.json" "$shell_config"
chmod 600 "$shell_config"
touch "$TEST_ROOT/shell-config-race-release"
if wait "$widget_pid"; then fail "widget migration must reject a concurrent shell.json edit"; fi
assert_eq "$(jq -r '.code' "$widget_result")" unsafe-state "a concurrent shell.json edit returned the wrong error"
assert_eq "$(jq -c . "$shell_config")" "$shell_config_concurrent" "widget migration overwrote a concurrent shell.json edit"
assert_missing "$widget_marker" "a rejected concurrent migration must not be recorded"
rm -f "$TEST_ROOT/concurrent-shell-config.json" "$TEST_ROOT/shell-config-race-ready" \
  "$TEST_ROOT/shell-config-race-release"

jq -cn --arg id 'anothadev.omachord' '
  {version:1,bar:{layout:{left:[],center:[],right:[]}},plugins:[{id:$id}],large:[range(0;200000) | 0]}
' >"$shell_config"
cp -- "$shell_config" "$TEST_ROOT/large-shell-config.json"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget migration must reject an oversized generated shell.json"
fi
assert_eq "$(jq -r '.code' "$widget_result")" unsafe-state "an oversized generated shell.json returned the wrong error"
cmp -s "$shell_config" "$TEST_ROOT/large-shell-config.json" \
  || fail "widget migration published an oversized generated shell.json"
assert_missing "$widget_marker" "a rejected oversized migration must not be recorded"
rm -f "$TEST_ROOT/large-shell-config.json"

write_shell_config "$shell_config_plugins_only" 644
: >"$TEST_ROOT/widget.log"
touch "$TEST_ROOT/shell-down"
"$RUNNER" widget ensure | jq -e '.ok and .placed == true and .migrated == true' >/dev/null
rm -f "$TEST_ROOT/shell-down"
assert_eq "$(stat -c %a "$shell_config")" 644 "the migration must preserve the shell.json mode"
assert_eq "$(jq -c '[.plugins, (.bar.layout.center | map(.id))]' "$shell_config")" \
  '[[],["omarchy.indicators","anothadev.omachord","omarchy.keyboard-layout","omarchy.weather","omarchy.clock"]]' \
  "the migration must not depend on a running shell"
assert_eq "$(wc -c <"$TEST_ROOT/widget.log")" 0 "a shell that is down must not be asked to place the widget"
"$RUNNER" widget forget | jq -e '.ok and .recorded == false' >/dev/null
write_shell_config '{"version":1,"bar":{"layout":{"center":[{"id":"omarchy.clock"}]}},"plugins":[{"id":"anothadev.omachord"}]}'
"$RUNNER" widget ensure | jq -e '.ok and .migrated == true' >/dev/null
assert_eq "$(jq -c '.bar.layout.center | map(.id)' "$shell_config")" '["omarchy.clock","anothadev.omachord"]' \
  "without an anchor the migrated widget must be appended to the center"
"$RUNNER" widget forget | jq -e '.ok and .recorded == false' >/dev/null

# An unreadable shell config is never migrated or recorded.
: >"$TEST_ROOT/widget.log"
write_shell_config 'not json'
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must fail on an invalid shell.json"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-config-invalid "an invalid shell.json returned the wrong error"
assert_missing "$widget_marker" "an invalid shell.json must not be recorded"
assert_eq "$(cat "$shell_config")" 'not json' "an invalid shell.json must be left untouched"
assert_eq "$(stat -c %a "$shell_config")" 600 "an invalid shell.json must be left untouched"
assert_eq "$(wc -c <"$TEST_ROOT/widget.log")" 0 "an invalid shell.json must not involve the shell"
"$RUNNER" widget status | jq -e '.ok and .recorded == false and .inBar == false and .inPlugins == false' >/dev/null

write_shell_config '{"version":2,"bar":{"layout":{"left":[],"center":[],"right":[]}},"plugins":[{"id":"anothadev.omachord"}]}'
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must reject an unsupported shell.json version"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-config-invalid "an unsupported shell.json version returned the wrong error"
assert_eq "$(jq -r '.version' "$shell_config")" 2 "widget migration downgraded shell.json"

write_shell_config '{"version":1,"bar":{"layout":"future-layout"},"plugins":[{"id":"anothadev.omachord"}]}'
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must reject malformed existing shell.json sections"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-config-invalid "malformed shell.json sections returned the wrong error"
assert_eq "$(jq -r '.bar.layout' "$shell_config")" future-layout "widget migration replaced malformed shell.json sections"

shell_config_target="$TEST_ROOT/dotfiles-shell.json"
printf '%s\n' "$shell_config_plugins_only" >"$shell_config_target"
rm -f "$shell_config"
ln -s "$shell_config_target" "$shell_config"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must reject a symlinked shell.json"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-config-invalid "a symlinked shell.json returned the wrong error"
[[ -L $shell_config ]] || fail "widget migration replaced the shell.json symlink"
assert_eq "$(jq -c . "$shell_config_target")" "$shell_config_plugins_only" "widget migration changed a symlink target"
rm -f "$shell_config" "$shell_config_target"

if "$RUNNER" widget ensure >"$widget_result"; then
  fail "widget ensure must fail without a shell.json"
fi
assert_eq "$(jq -r '.code' "$widget_result")" shell-config-invalid "a missing shell.json returned the wrong error"
assert_missing "$widget_marker" "a missing shell.json must not be recorded"
assert_missing "$shell_config" "a missing shell.json must not be created"

# An invalid marker fails closed instead of placing the widget again.
write_shell_config "$shell_config_in_bar"
printf 'garbage\n' >"$widget_marker"
if "$RUNNER" widget ensure >"$widget_result"; then
  fail "an invalid widget record must fail closed"
fi
assert_eq "$(jq -r '.code' "$widget_result")" unsafe-state "an invalid widget record returned the wrong error"
rm -f "$widget_result" "$widget_marker" "$shell_config"
pass "bar widget placement is recorded once"

printf 'Runner tests passed.\n'
