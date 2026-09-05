#!/bin/bash
# Revision-bound UI execution through the real runner and isolated mock desktop.
set -euo pipefail
umask 077
for test_override in "${!OMACHORD_@}"; do [[ -z $test_override ]] || unset "$test_override"; done
unset BASH_ENV ENV
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
RUNNER="$ROOT/bin/omachord"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/omachord-manual-revision.XXXXXX")
INSTRUMENTED_RUNNER="$TEST_ROOT/instrumented/bin/omachord"
export TEST_ROOT HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/.config"
export XDG_STATE_HOME="$TEST_ROOT/state" XDG_DATA_HOME="$TEST_ROOT/data" XDG_RUNTIME_DIR="$TEST_ROOT/runtime" TMPDIR="$TEST_ROOT/tmp"
export PATH="$TEST_ROOT/bin:/usr/bin:/bin" OMACHORD_RUNNER_PATH="$RUNNER"
mkdir -p "$HOME/.config/omarchy" "$HOME/.config/hypr" "$XDG_RUNTIME_DIR" "$TMPDIR" "$TEST_ROOT/bin"
cleanup() { touch "$TEST_ROOT/apply.release"; wait || true; rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

# Only explicit fault-injection calls use this disposable plugin fixture.
python3 "$ROOT/test/fs_test_support.py" "$ROOT" "$TEST_ROOT/instrumented" >/dev/null
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
wait_for_path() { for _ in {1..1000}; do [[ -e $1 ]] && return 0; sleep 0.01; done; fail "timeout waiting for $1"; }
cat >"$TEST_ROOT/bin/omarchy" <<'STUB'
#!/bin/bash
[[ "$*" == 'menu keybindings --print' ]]
STUB
cat >"$TEST_ROOT/bin/hyprctl" <<'STUB'
#!/bin/bash
[[ ${1:-} == reload || ${1:-} == configerrors ]]
STUB
cat >"$TEST_ROOT/bin/flock" <<'STUB'
#!/bin/bash
[[ -z ${TEST_LOCK_READY:-} ]] || touch "$TEST_LOCK_READY"
exec /usr/bin/flock "$@"
STUB
cat >"$TEST_ROOT/bin/effect" <<'STUB'
#!/bin/bash
printf '%s\n' "$1" >>"$TEST_ROOT/effects"
STUB
chmod +x "$TEST_ROOT/bin/"*
CONFIG_PATH="$HOME/.config/omarchy/omachord.json"
STATE_DIR="$XDG_STATE_HOME/omarchy/omachord"
revision() { "$RUNNER" config snapshot | jq -er .revision; }
apply() { printf '%s\n' "$1" | "$RUNNER" config apply "$(revision)" >/dev/null; }
A=$(jq -cn --arg program "$TEST_ROOT/bin/effect" '{version:1,routines:[
 {id:"alpha",name:"Alpha",enabled:true,triggers:[],actions:[{type:"exec",program:$program,args:["A"]}]},
 {id:"beta",name:"Beta",enabled:true,triggers:[],actions:[]}] }')
apply "$A"
reviewed=$(revision)
B=$(jq -c '.routines[0].actions[0].args=["B"]' <<<"$A")
printf '%s\n' "$B" | env OMACHORD_FS_TEST_MATCH="$CONFIG_PATH" OMACHORD_FS_TEST_PAUSE=before-publish \
  OMACHORD_FS_TEST_READY="$TEST_ROOT/apply.ready" OMACHORD_FS_TEST_RELEASE="$TEST_ROOT/apply.release" \
  "$INSTRUMENTED_RUNNER" config apply "$reviewed" >"$TEST_ROOT/apply.json" & applying=$!
wait_for_path "$TEST_ROOT/apply.ready"
env TEST_LOCK_READY="$TEST_ROOT/run.lock-ready" "$RUNNER" run alpha test "$reviewed" >"$TEST_ROOT/run.json" & queued=$!
wait_for_path "$TEST_ROOT/run.lock-ready"
touch "$TEST_ROOT/apply.release"
wait "$applying"
if wait "$queued"; then fail 'queued manual Run executed a changed definition'; fi
jq -e '.code == "stale-config"' "$TEST_ROOT/run.json" >/dev/null
[[ ! -e $TEST_ROOT/effects ]] || fail 'stale manual Run had effects'
printf 'PASS: queued UI Run rejects an edit committed before its config lock\n'

latest=$(revision)
"$RUNNER" run alpha test "$latest" >/dev/null
"$RUNNER" activate alpha manual "$latest" >/dev/null
[[ $(cat "$TEST_ROOT/effects") == $'B\nB' ]] || fail 'current reviewed revision did not run'
# Whole-config binding intentionally rejects unrelated saves; an explicit new
# click/retry may use the newly inspected revision.
apply "$(jq -c '.routines[1].name="Unrelated edit"' <<<"$B")"
if "$RUNNER" activate alpha test "$latest" >"$TEST_ROOT/run.json"; then fail 'unrelated revision change was silently substituted'; fi
jq -e '.code == "stale-config"' "$TEST_ROOT/run.json" >/dev/null
"$RUNNER" run alpha test "$(revision)" >/dev/null
"$RUNNER" run alpha >/dev/null
"$RUNNER" activate alpha test >/dev/null
[[ $(wc -l <"$TEST_ROOT/effects") == 5 ]] || fail 'fresh retry or omitted-revision CLI behavior changed'
printf 'PASS: current revision works; unrelated saves require retry; explicit CLI stays latest\n'

# Swap the canonical file and commit immediately after the loader observes the
# old commitment. Resolution must still use the same captured old document.
cat >"$TEST_ROOT/bin/jq" <<'STUB'
#!/bin/bash
set -euo pipefail
if [[ ${TEST_SWAP_ON_COMMIT:-} == 1 && ${!#} == "$XDG_STATE_HOME/omarchy/omachord/config.commit.json" && ! -e $TEST_ROOT/swapped ]]; then
  captured=$(/usr/bin/jq "$@")
  cp "$TEST_ROOT/replacement.json" "$HOME/.config/omarchy/omachord.json"
  cp "$TEST_ROOT/replacement-commit.json" "$XDG_STATE_HOME/omarchy/omachord/config.commit.json"
  touch "$TEST_ROOT/swapped"
  printf '%s\n' "$captured"
else
  exec /usr/bin/jq "$@"
fi
STUB
chmod +x "$TEST_ROOT/bin/jq"
for operation in run activate; do
  apply "$A"
  reviewed=$(revision)
  printf '%s\n' "$B" >"$TEST_ROOT/replacement.json"
  replaced="sha256:$(sha256sum "$TEST_ROOT/replacement.json" | awk '{print $1}')"
  jq -cn --arg revision "$replaced" '{version:1,revision:$revision}' >"$TEST_ROOT/replacement-commit.json"
  rm -f "$TEST_ROOT/swapped"
  env TEST_SWAP_ON_COMMIT=1 "$RUNNER" "$operation" alpha test "$reviewed" >/dev/null
  [[ -e $TEST_ROOT/swapped ]] || fail 'snapshot-substitution fixture did not run'
  [[ $(tail -1 "$TEST_ROOT/effects") == A ]] || fail 'execution loaded newer bytes after its approval snapshot'
done
printf 'PASS: Run and Activate execute the same snapshot whose revision was approved\n'

# Explicit recovery/End does not inherit an old start's revision requirement.
STATEFUL=$(jq -c '.routines[0].keepUntil={minutes:10}' <<<"$A")
apply "$STATEFUL"
reviewed=$(revision)
"$RUNNER" activate alpha test "$reviewed" >/dev/null
apply "$(jq -c '.routines[1].name="Another unrelated edit"' <<<"$STATEFUL")"
if "$RUNNER" run alpha test "$reviewed" >"$TEST_ROOT/run.json"; then fail 'stale bound toggle unexpectedly succeeded'; fi
"$RUNNER" deactivate alpha manual | jq -e '.ok and .state=="deactivated"' >/dev/null
for operation in run activate; do
  if "$RUNNER" "$operation" alpha test '' >"$TEST_ROOT/run.json"; then fail 'empty explicit revision silently became latest'; fi
  jq -e '.code == "usage"' "$TEST_ROOT/run.json" >/dev/null
done
printf 'PASS: explicit End remains available; empty supplied revisions fail closed\n'
