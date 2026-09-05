#!/bin/bash
# Isolated authorization and recovery regressions; never invokes the real desktop.
set -euo pipefail
umask 077
# Discard caller path overrides and fault hooks before constructing this fixture.
for test_override in "${!OMACHORD_@}"; do
  [[ -z $test_override ]] || unset "$test_override"
done
unset BASH_ENV ENV
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/bin/omachord"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omachord-authorization.XXXXXX")
export TEST_ROOT
export HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
export XDG_STATE_HOME="$TEST_ROOT/state" XDG_DATA_HOME="$TEST_ROOT/data"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime" TMPDIR="$TEST_ROOT/tmp"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin" OMACHORD_RUNNER_PATH="$RUNNER"
mkdir -p "$HOME/.config/hypr" "$HOME/.config/omarchy" "$XDG_RUNTIME_DIR" "$TMPDIR" "$TEST_ROOT/bin"
cleanup() {
  # Release only this fixture's deterministic barriers before removing its tree.
  touch "$TEST_ROOT/catalogue.release" "$TEST_ROOT/disconnect.release" \
    "$TEST_ROOT/icon.release" "$TEST_ROOT/auto.release" "$TEST_ROOT/recovery.release"
  wait || true
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$*"; }
wait_for_path() {
  for _ in {1..500}; do [[ -e $1 ]] && return 0; sleep 0.01; done
  fail "synchronization timed out: $1"
}
cat >"$TEST_ROOT/bin/omarchy" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$*" == 'menu keybindings --print' ]] || exit 1
if [[ -e $TEST_ROOT/hold-catalogue ]]; then
  touch "$TEST_ROOT/catalogue.ready"
  while [[ ! -e $TEST_ROOT/catalogue.release ]]; do sleep 0.01; done
fi
STUB
cat >"$TEST_ROOT/bin/hyprctl" <<'STUB'
#!/bin/bash
case ${1:-} in
  configerrors) ;;
  reload) printf 'reload\n' >>"$TEST_ROOT/reloads"; [[ ! -e $TEST_ROOT/fail-reload ]] ;;
  *) exit 1 ;;
esac
STUB
cat >"$TEST_ROOT/bin/flock" <<'STUB'
#!/bin/bash
[[ -z ${AUTO_LOCK_READY:-} ]] || touch "$AUTO_LOCK_READY"
exec /usr/bin/flock "$@"
STUB
cat >"$TEST_ROOT/bin/effect-fail" <<'STUB'
#!/bin/bash
printf 'effect\n' >>"$TEST_ROOT/effects"
exit 1
STUB
cat >"$TEST_ROOT/bin/omarchy-shell" <<'STUB'
#!/bin/bash
case "$*" in
  'nightlight status') if [[ -e $TEST_ROOT/nightlight ]]; then printf '{"enabled":true}\n'; else printf '{"enabled":false}\n'; fi ;;
  'nightlight enable') touch "$TEST_ROOT/nightlight" ;;
  'nightlight disable') [[ ! -e $TEST_ROOT/fail-restore ]] || exit 1; rm -f "$TEST_ROOT/nightlight" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TEST_ROOT/bin/"*
CONFIG_PATH="$HOME/.config/omarchy/omachord.json"
STATE_DIR="$XDG_STATE_HOME/omarchy/omachord"
ICON_PATH="$XDG_DATA_HOME/icons/hicolor/scalable/apps/anothadev.omachord.svg"
BASE_CONFIG='{"version":1,"routines":[{"id":"probe","name":"Probe","enabled":true,"triggers":[{"type":"shortcut","keys":"SUPER + M","override":false}],"actions":[]}]}'
revision() { "$RUNNER" config snapshot | jq -er '.revision'; }
apply() { printf '%s\n' "$1" | "$RUNNER" config apply "$(revision)" >/dev/null; }
seed() { apply "$BASE_CONFIG"; "$RUNNER" connect >/dev/null; }
legacy_icon() {
  jq '.version=1 | del(.iconCreated)' "$STATE_DIR/connection.json" >"$TEST_ROOT/legacy.json"
  cp "$TEST_ROOT/legacy.json" "$STATE_DIR/connection.json"
  rm -- "$ICON_PATH"
}
icon_test() {
  seed
  legacy_icon
  cp "$STATE_DIR/connection.json" "$TEST_ROOT/ownership.before"
  touch "$TEST_ROOT/hold-catalogue"
  "$RUNNER" connect >"$TEST_ROOT/result" & local upgrade=$!
  wait_for_path "$TEST_ROOT/catalogue.ready"
  printf 'unowned concurrent icon\n' >"$ICON_PATH"
  touch "$TEST_ROOT/catalogue.release"
  if wait "$upgrade"; then fail 'legacy repair replaced a concurrent unowned icon'; fi
  [[ $(cat "$ICON_PATH") == 'unowned concurrent icon' ]] || fail 'concurrent icon was changed'
  cmp "$STATE_DIR/connection.json" "$TEST_ROOT/ownership.before" || fail 'failed migration promoted ownership'
  rm "$TEST_ROOT/hold-catalogue" "$ICON_PATH"
  "$RUNNER" connect | jq -e '.ok and .repaired' >/dev/null
  cmp "$ROOT/assets/omachord-icon.svg" "$ICON_PATH"
  printf 'damaged owned icon\n' >"$ICON_PATH"
  "$RUNNER" connect | jq -e '.ok and .repaired' >/dev/null
  cmp "$ROOT/assets/omachord-icon.svg" "$ICON_PATH"
  legacy_icon
  env OMACHORD_FS_TEST_MATCH="$ICON_PATH" OMACHORD_FS_TEST_PAUSE=before-publish \
    OMACHORD_FS_TEST_READY="$TEST_ROOT/icon.ready" OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/icon.release" \
    "$RUNNER" connect >"$TEST_ROOT/result" & upgrade=$!
  wait_for_path "$TEST_ROOT/icon.ready"
  printf 'late unowned icon\n' >"$ICON_PATH"
  touch "$TEST_ROOT/icon.release"
  if wait "$upgrade"; then fail 'missing icon baseline was widened at publication'; fi
  [[ $(cat "$ICON_PATH") == 'late unowned icon' ]] || fail 'late icon collision was lost in rollback'
  jq -e '.version == 1 and (.iconCreated != true)' "$STATE_DIR/connection.json" >/dev/null
  pass 'legacy icon acquisition preserves concurrent unowned files and repairs owned files'
}
off_test() {
  seed
  env OMACHORD_FS_TEST_MATCH="$STATE_DIR/connection.disabled.json" \
    OMACHORD_FS_TEST_PAUSE=before-publish OMACHORD_FS_TEST_READY="$TEST_ROOT/disconnect.ready" \
    OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/disconnect.release" \
    "$RUNNER" disconnect >"$TEST_ROOT/disconnect.json" & local disconnect=$!
  wait_for_path "$TEST_ROOT/disconnect.ready"
  env AUTO_LOCK_READY="$TEST_ROOT/autostart.lock-ready" "$RUNNER" autostart >"$TEST_ROOT/autostart.json" & local autostart=$!
  wait_for_path "$TEST_ROOT/autostart.lock-ready"
  touch "$TEST_ROOT/disconnect.release"
  wait "$disconnect"
  wait "$autostart"
  jq -e '.ok and .disabled and .skipped and (.connected | not)' "$TEST_ROOT/autostart.json" >/dev/null \
    || fail 'queued autostart overrode completed Off'
  [[ -f $STATE_DIR/connection.disabled.json && ! -e $HOME/.config/hypr/omachord.lua ]] || fail 'Off did not persist'
  "$RUNNER" connect | jq -e '.ok and .connected' >/dev/null
  [[ ! -e $STATE_DIR/connection.disabled.json ]] || fail 'explicit connect did not clear Off'
  # Reverse order: automatic repair owns the lock first, then Disconnect wins.
  rm "$ICON_PATH"
  env OMACHORD_FS_TEST_MATCH="$ICON_PATH" OMACHORD_FS_TEST_PAUSE=before-publish \
    OMACHORD_FS_TEST_READY="$TEST_ROOT/auto.ready" OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/auto.release" \
    "$RUNNER" autostart >"$TEST_ROOT/autostart.json" & autostart=$!
  wait_for_path "$TEST_ROOT/auto.ready"
  env AUTO_LOCK_READY="$TEST_ROOT/disconnect.lock-ready" "$RUNNER" disconnect >"$TEST_ROOT/disconnect.json" & disconnect=$!
  wait_for_path "$TEST_ROOT/disconnect.lock-ready"
  touch "$TEST_ROOT/auto.release"
  wait "$autostart"
  wait "$disconnect"
  [[ -e $STATE_DIR/connection.disabled.json && ! -e $ICON_PATH ]] || fail 'later Disconnect did not win lock ordering'
  "$RUNNER" autostart | jq -e '.ok and .disabled and .skipped' >/dev/null
  printf '{}\n' >"$STATE_DIR/connection.disabled.json"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'malformed Off was ignored'; fi
  jq -e '.code == "unsafe-state"' "$TEST_ROOT/result" >/dev/null
  pass 'autostart respects Off in config-lock order; explicit Connect can reenable'
}
authorization_test() {
  seed
  cp "$STATE_DIR/config.commit.json" "$TEST_ROOT/commit.before"
  cp "$HOME/.config/hypr/omachord.lua" "$TEST_ROOT/generated.before"
  local original changed approved
  original=$(cat "$CONFIG_PATH")
  changed=$(jq -c --arg program "$TEST_ROOT/bin/effect-fail" '.routines[0].actions=[{type:"exec",program:$program,args:[]}]' <<<"$original")
  printf '%s\n' "$changed" >"$CONFIG_PATH"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'autostart approved changed config'; fi
  jq -e '.code == "uncommitted-config"' "$TEST_ROOT/result" >/dev/null
  cmp "$STATE_DIR/config.commit.json" "$TEST_ROOT/commit.before"
  cmp "$HOME/.config/hypr/omachord.lua" "$TEST_ROOT/generated.before"
  if "$RUNNER" connect >"$TEST_ROOT/result"; then fail 'bare Connect approved changed config'; fi
  approved=$(revision)
  "$RUNNER" connect "$approved" | jq -e '.ok and .connected' >/dev/null
  "$RUNNER" config snapshot | jq -e '.committed' >/dev/null
  for marker in missing malformed; do
    if [[ $marker == missing ]]; then rm "$STATE_DIR/config.commit.json"; else printf '{}\n' >"$STATE_DIR/config.commit.json"; fi
    cp "$CONFIG_PATH" "$TEST_ROOT/config.before"
    if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail "autostart approved $marker commit"; fi
    cmp "$CONFIG_PATH" "$TEST_ROOT/config.before"
    "$RUNNER" config snapshot | jq -e '.committed == false' >/dev/null
    "$RUNNER" connect "$(revision)" >/dev/null
  done
  rm "$ICON_PATH"
  "$RUNNER" autostart | jq -e '.ok and .repaired' >/dev/null
  "$RUNNER" autostart | jq -e '.ok and .alreadyConnected' >/dev/null
  [[ ! -e $TEST_ROOT/effects ]] || fail 'startup executed a routine effect'
  pass 'startup repairs committed artifacts but cannot approve changed or unmarked executable config'
}
bootstrap_test() {
  "$RUNNER" autostart | jq -e '.ok and .connected' >/dev/null
  "$RUNNER" config snapshot | jq -e '.committed and (.config.routines | length == 0)' >/dev/null
  pass 'truly missing config and commit permit safe empty bootstrap'
}
unknown_bootstrap_test() {
  printf '%s\n' "$BASE_CONFIG" >"$CONFIG_PATH"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'new nonempty unmarked config was approved'; fi
  [[ ! -e $STATE_DIR/config.commit.json && ! -e $ICON_PATH ]] || fail 'unknown bootstrap mutated integration'
  # Existing empty JSON still lacks a review/commit history; only absence is bootstrap.
  printf '{"version":1,"routines":[]}\n' >"$CONFIG_PATH"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'existing unmarked file was silently approved'; fi
  pass 'unmarked files require explicit review even on first installation'
}
rollback_test() {
  seed
  local before after
  before=$(sha256sum "$STATE_DIR/config.commit.json")
  cp "$CONFIG_PATH" "$TEST_ROOT/config.before"
  rm "$ICON_PATH"
  touch "$TEST_ROOT/fail-reload"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'failed reload reported success'; fi
  after=$(sha256sum "$STATE_DIR/config.commit.json")
  [[ $before == "$after" ]] || fail 'failed repair changed committed revision'
  cmp "$CONFIG_PATH" "$TEST_ROOT/config.before"
  rm "$TEST_ROOT/fail-reload"
  "$RUNNER" autostart | jq -e '.ok and .repaired' >/dev/null
  # Lost canonical bytes with a previous commit must never become empty approval.
  rm "$CONFIG_PATH"
  if "$RUNNER" autostart >"$TEST_ROOT/result"; then fail 'lost config was silently replaced with empty bootstrap'; fi
  [[ ! -e $CONFIG_PATH ]] || fail 'lost canonical data was rewritten'
  pass 'reload rollback retains approval, and prior commit prevents lost-config bootstrap'
}
lifecycle_config() {
  jq -cn --arg program "$TEST_ROOT/bin/effect-fail" '{version:1,routines:[{
    id:"lifecycle",name:"Lifecycle",enabled:true,triggers:[],keepUntil:{minutes:10},actions:[{type:"delay",milliseconds:0}],
    onEnd:{mode:"actions",actions:[{type:"exec",program:$program,args:[]},{type:"exec",program:"/usr/bin/true",args:[]}]}
  }]}'
}
plan_test() {
  local original edited
  original=$(lifecycle_config)
  apply "$original"
  "$RUNNER" activate lifecycle >/dev/null
  if "$RUNNER" deactivate lifecycle >"$TEST_ROOT/result"; then fail 'fixture effect did not fail'; fi
  [[ $(wc -l <"$TEST_ROOT/effects") == 1 ]] || fail 'effect was not consumed once'
  for edit in \
    '.onEnd.actions |= ([{type:"exec",program:"/usr/bin/true",args:[]}] + .)' \
    '.onEnd.actions |= reverse' \
    '.onEnd.actions |= .[1:]' \
    '.onEnd.actions[1].program = "/usr/bin/false"' \
    '.onEnd.mode = "none" | .onEnd.actions = []'; do
    edited=$(jq -c ".routines[0] |= ($edit)" <<<"$original")
    if apply "$edited"; then fail 'config apply changed an active end plan'; fi
    [[ $(wc -l <"$TEST_ROOT/effects") == 1 ]] || fail 'edit replayed a consumed effect'
  done
  apply "$(jq -c '.routines[0].name = "Renamed while active"' <<<"$original")"
  # A fresh CLI process retries the original plan and must skip the consumed effect.
  "$RUNNER" deactivate lifecycle >/dev/null
  [[ $(wc -l <"$TEST_ROOT/effects") == 1 ]] || fail 'unchanged recovery replayed consumed effect'
  # Even before the first end action, an active plan is frozen.
  "$RUNNER" activate lifecycle >/dev/null
  if apply "$edited"; then fail 'edit before the first end action changed the active plan'; fi
  # A manual file edit plus explicit Connect must not rebind recovery progress.
  printf '%s\n' "$edited" >"$CONFIG_PATH"
  if "$RUNNER" connect "$(revision)" >"$TEST_ROOT/result"; then fail 'Connect rebound the active plan'; fi
  [[ $(wc -l <"$TEST_ROOT/effects") == 1 ]] || fail 'repair executed new ending'
  printf '%s\n' "$original" >"$CONFIG_PATH"
  "$RUNNER" connect "$(revision)" >/dev/null
  if "$RUNNER" deactivate lifecycle >"$TEST_ROOT/result"; then fail 'second lifecycle effect did not fail'; fi
  "$RUNNER" deactivate lifecycle >/dev/null
  [[ $(wc -l <"$TEST_ROOT/effects") == 2 ]] || fail 'new lifecycle consumed wrong number of effects'
  pass 'active end plans reject insertion, reorder, removal, replacement and mode changes across retries'
}
recovery_test() {
  local original snapshot="$STATE_DIR/active/lifecycle.json" inspected old_revision
  original=$(lifecycle_config | jq -c '.routines[0].actions=[{type:"nightlight",value:true,restore:true}]')
  apply "$original"
  "$RUNNER" activate lifecycle >/dev/null
  # Real v1 shape, with no inferred plan identity, including consumed progress.
  jq '.version=1 | del(.endPlanDigest) | .endActionIndex=1' "$snapshot" >"$TEST_ROOT/legacy-active.json"
  cp "$TEST_ROOT/legacy-active.json" "$snapshot"
  if "$RUNNER" deactivate lifecycle >"$TEST_ROOT/result"; then fail 'legacy actions acquired current plan identity'; fi
  [[ ! -e $TEST_ROOT/effects ]] || fail 'legacy recovery ran end actions'
  [[ -e $snapshot ]] || fail 'legacy recovery record was discarded'
  inspected=$("$RUNNER" recovery inspect lifecycle)
  old_revision=$(jq -er '.revision' <<<"$inspected")
  jq -e '.snapshot.version == 1 and .snapshot.setters[0].before == false and .snapshot.setters[0].applied == true' <<<"$inspected" >/dev/null
  # Revision changes invalidate approval even if only lifecycle metadata changes.
  jq '.activatedAt += " "' "$snapshot" >"$TEST_ROOT/changed-active.json"
  cp "$TEST_ROOT/changed-active.json" "$snapshot"
  if "$RUNNER" recovery restore lifecycle "$old_revision" --skip-end-actions >"$TEST_ROOT/result"; then fail 'stale recovery approval accepted'; fi
  jq -e '.code == "stale-recovery"' "$TEST_ROOT/result" >/dev/null
  old_revision=$("$RUNNER" recovery inspect lifecycle | jq -er '.revision')
  if "$RUNNER" recovery restore lifecycle "$old_revision" >"$TEST_ROOT/result"; then fail 'recovery silently skipped executable actions'; fi
  touch "$TEST_ROOT/nightlight" "$TEST_ROOT/fail-restore"
  if "$RUNNER" recovery restore lifecycle "$old_revision" --skip-end-actions >"$TEST_ROOT/result"; then fail 'failed setter restore reported success'; fi
  jq -e '.version == 2 and .onEndMode == "restore" and .setters[0].before == false and .setters[0].applied == true' "$snapshot" >/dev/null
  [[ -e $TEST_ROOT/nightlight && ! -e $TEST_ROOT/effects ]] || fail 'failed recovery lost state or invoked actions'
  rm "$TEST_ROOT/fail-restore"
  # A regular retry sees the durable skip decision, even after restart.
  "$RUNNER" deactivate lifecycle >/dev/null
  [[ ! -e $snapshot && ! -e $TEST_ROOT/nightlight && ! -e $TEST_ROOT/effects ]] || fail 'restore-only recovery did not complete safely'
  pass 'legacy recovery requires explicit version-bound skipping and retains typed restoration on failure'
}
legacy_progress_test() {
  local original snapshot="$STATE_DIR/active/lifecycle.json" progress inspected
  original=$(lifecycle_config)
  apply "$original"
  for progress in missing 0 1 2; do
    "$RUNNER" activate lifecycle >/dev/null
    if [[ $progress == missing ]]; then
      jq '.version=1 | del(.endPlanDigest,.endActionIndex)' "$snapshot" >"$TEST_ROOT/legacy.json"
    else
      jq --argjson index "$progress" '.version=1 | del(.endPlanDigest) | .endActionIndex=$index' "$snapshot" >"$TEST_ROOT/legacy.json"
    fi
    cp "$TEST_ROOT/legacy.json" "$snapshot"
    if "$RUNNER" deactivate lifecycle >"$TEST_ROOT/result"; then fail "legacy progress $progress acquired the current plan"; fi
    [[ ! -e $TEST_ROOT/effects ]] || fail "legacy progress $progress executed commands"
    inspected=$("$RUNNER" recovery inspect lifecycle | jq -er '.revision')
    "$RUNNER" recovery restore lifecycle "$inspected" --skip-end-actions >/dev/null
    [[ ! -e $snapshot ]] || fail "legacy progress $progress was not recoverable"
  done
  for mode in restore none; do
    apply "$(jq -c --arg mode "$mode" '.routines[0].onEnd={mode:$mode,actions:[]}' <<<"$original")"
    "$RUNNER" activate lifecycle >/dev/null
    jq '.version=1 | del(.endPlanDigest)' "$snapshot" >"$TEST_ROOT/legacy.json"
    cp "$TEST_ROOT/legacy.json" "$snapshot"
    "$RUNNER" deactivate lifecycle >/dev/null
  done
  pass 'legacy missing, zero, partial and completed progress cannot invent history; restore/none remain usable'
}
completed_plan_test() {
  local original changed snapshot="$STATE_DIR/active/lifecycle.json" inspected
  original=$(lifecycle_config | jq -c '.routines[0].onEnd.actions=[{type:"exec",program:"/usr/bin/true",args:[]}]')
  apply "$original"
  "$RUNNER" activate lifecycle >/dev/null
  if env OMACHORD_FS_TEST_MATCH="$snapshot" OMACHORD_FS_TEST_FAIL_REMOVE=1 \
    "$RUNNER" deactivate lifecycle >"$TEST_ROOT/result"; then fail 'failed completed-record removal was ignored'; fi
  jq -e '.endActionIndex == 1' "$snapshot" >/dev/null
  changed=$(jq -c --arg program "$TEST_ROOT/bin/effect-fail" '.routines[0].onEnd.actions |= [{type:"exec",program:$program,args:[]}] + .' <<<"$original")
  if apply "$changed"; then fail 'fully consumed plan was edited before record removal'; fi
  # Simulate an old/external writer committing another list despite the active
  # record; ending still independently checks the bound digest at execution.
  printf '%s\n' "$changed" >"$CONFIG_PATH"
  inspected=$(revision)
  jq -cn --arg revision "$inspected" '{version:1,revision:$revision}' >"$STATE_DIR/config.commit.json"
  for reason in manual shortcut test; do
    if "$RUNNER" deactivate lifecycle "$reason" >"$TEST_ROOT/result"; then fail 'ending applied completed cursor to another committed plan'; fi
    jq -e '.error | test("active end-action plan changed")' "$TEST_ROOT/result" >/dev/null
  done
  [[ ! -e $TEST_ROOT/effects ]] || fail 'changed committed ending executed'
  # Explicit skip is durable even when final record removal fails.
  inspected=$("$RUNNER" recovery inspect lifecycle | jq -er '.revision')
  if env OMACHORD_FS_TEST_MATCH="$snapshot" OMACHORD_FS_TEST_FAIL_REMOVE=1 \
    "$RUNNER" recovery restore lifecycle "$inspected" --skip-end-actions >"$TEST_ROOT/result"; then fail 'failed recovery removal reported success'; fi
  jq -e '.onEndMode == "restore"' "$snapshot" >/dev/null
  "$RUNNER" deactivate lifecycle >/dev/null
  [[ ! -e $TEST_ROOT/effects && ! -e $snapshot ]] || fail 'completed recovery replayed work'
  pass 'completed checkpoints remain bound and explicit skip survives failed removal'
}
recovery_cas_test() {
  local original snapshot="$STATE_DIR/active/lifecycle.json" inspected pid
  original=$(lifecycle_config)
  apply "$original"
  "$RUNNER" activate lifecycle >/dev/null
  inspected=$("$RUNNER" recovery inspect lifecycle | jq -er '.revision')
  env OMACHORD_FS_TEST_MATCH="$snapshot" OMACHORD_FS_TEST_PAUSE=before-publish \
    OMACHORD_FS_TEST_READY="$TEST_ROOT/recovery.ready" OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/recovery.release" \
    "$RUNNER" recovery restore lifecycle "$inspected" --skip-end-actions >"$TEST_ROOT/result" & pid=$!
  wait_for_path "$TEST_ROOT/recovery.ready"
  jq '.activatedAt += " "' "$snapshot" >"$TEST_ROOT/concurrent-snapshot.json"
  cp "$TEST_ROOT/concurrent-snapshot.json" "$snapshot"
  touch "$TEST_ROOT/recovery.release"
  if wait "$pid"; then fail 'recovery approval survived concurrent snapshot replacement'; fi
  cmp "$TEST_ROOT/concurrent-snapshot.json" "$snapshot"
  [[ ! -e $TEST_ROOT/effects ]] || fail 'conflicting recovery executed commands'
  pass 'recovery CAS preserves a record replaced after inspection and before publication'
}
case ${1:-all} in
  icon) icon_test ;;
  off) off_test ;;
  authorization) authorization_test ;;
  bootstrap) bootstrap_test ;;
  unknown-bootstrap) unknown_bootstrap_test ;;
  rollback) rollback_test ;;
  plan) plan_test ;;
  recovery) recovery_test ;;
  legacy-progress) legacy_progress_test ;;
  completed-plan) completed_plan_test ;;
  recovery-cas) recovery_cas_test ;;
  all) for scenario in icon off authorization bootstrap unknown-bootstrap rollback plan recovery legacy-progress completed-plan recovery-cas; do "$ROOT/test/authorization-test.sh" "$scenario"; done ;;
  *) fail 'unknown test selection' ;;
esac
