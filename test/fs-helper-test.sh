#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/bin/omachord-fs"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_ROOT=$(mktemp -d "$TEST_TMP/omachord-fs-test.XXXXXX")

cleanup() {
  rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_no_transaction_files() {
  if find "$1" -maxdepth 1 -name '.omachord*' -print -quit | grep -q .; then
    fail "filesystem helper left a transaction file in $1"
  fi
}

run_parent_swap() {
  local replacement=$1 root="$TEST_ROOT/$1" parent ready release result pid
  mkdir -p -m 700 "$root/parent" "$root/sentinel"
  parent="$root/parent"
  ready="$root/ready"
  release="$root/release"
  result="$root/result"

  printf '%s' payload \
    | env OMACHORD_FS_TEST_MATCH="$parent/value" OMACHORD_FS_TEST_PAUSE=before-publish \
        OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
        "$HELPER" atomic-write "$parent/value" 600 private "$root/archive" >"$result" &
  pid=$!
  for _ in {1..500}; do
    [[ -e $ready ]] && break
    sleep 0.01
  done
  [[ -e $ready ]] || fail "filesystem helper did not reach its parent-swap window"
  mv "$parent" "$root/pinned-parent"
  if [[ $replacement == symlink ]]; then
    ln -s "$root/sentinel" "$parent"
  else
    mkdir -m 700 "$parent"
  fi
  touch "$release"
  if wait "$pid"; then fail "filesystem helper accepted a replaced parent"; fi
  grep -Fq 'parent-changed' "$result" || fail "parent replacement returned the wrong error"
  [[ ! -e $root/sentinel/value && ! -e $parent/value ]] \
    || fail "filesystem helper wrote through a replaced parent"
  assert_no_transaction_files "$root/pinned-parent"
}

run_parent_swap symlink
run_parent_swap directory

for operation in cas-write cas-remove; do
  root="$TEST_ROOT/$operation-parent"
  mkdir -p -m 700 "$root/parent" "$root/replacement"
  printf '%s' baseline >"$root/parent/value"
  chmod 600 "$root/parent/value"
  baseline_fingerprint="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
  ready="$root/ready"
  release="$root/release"
  result="$root/result"
  if [[ $operation == cas-write ]]; then
    printf '%s' candidate \
      | env OMACHORD_FS_TEST_MATCH="$root/parent/value" OMACHORD_FS_TEST_PAUSE=before-publish \
          OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
          "$HELPER" cas-write "$root/parent/value" 600 "$baseline_fingerprint" private "$root/archive" >"$result" &
  else
    env OMACHORD_FS_TEST_MATCH="$root/parent/value" OMACHORD_FS_TEST_PAUSE=before-publish \
      OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
      "$HELPER" cas-remove "$root/parent/value" "$baseline_fingerprint" private "$root/archive" >"$result" &
  fi
  pid=$!
  for _ in {1..500}; do
    [[ -e $ready ]] && break
    sleep 0.01
  done
  [[ -e $ready ]] || fail "$operation did not reach its parent-swap window"
  mv "$root/parent" "$root/pinned-parent"
  mv "$root/replacement" "$root/parent"
  printf '%s' sentinel >"$root/parent/value"
  chmod 600 "$root/parent/value"
  touch "$release"
  if wait "$pid"; then fail "$operation accepted a replaced parent"; fi
  grep -Fq 'parent-changed' "$result" || fail "$operation parent replacement returned the wrong error"
  [[ $(cat "$root/parent/value") == sentinel ]] || fail "$operation changed the replacement directory"
  [[ $(cat "$root/pinned-parent/value") == baseline ]] || fail "$operation changed the pinned original"
  assert_no_transaction_files "$root/pinned-parent"
done

root="$TEST_ROOT/missing-remove-parent"
mkdir -p -m 700 "$root/parent" "$root/replacement"
ready="$root/ready"
release="$root/release"
result="$root/result"
env OMACHORD_FS_TEST_MATCH="$root/parent/value" OMACHORD_FS_TEST_PAUSE=before-publish \
  OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
  "$HELPER" cas-remove "$root/parent/value" missing private "$root/archive" >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "missing removal did not reach its parent-swap window"
mv "$root/parent" "$root/pinned-parent"
mv "$root/replacement" "$root/parent"
printf '%s' sentinel >"$root/parent/value"
chmod 600 "$root/parent/value"
touch "$release"
if wait "$pid"; then fail "missing removal accepted a replaced parent"; fi
grep -Fq 'parent-changed' "$result" || fail "missing removal parent replacement returned the wrong error"
[[ $(cat "$root/parent/value") == sentinel ]] || fail "missing removal changed the replacement directory"
printf 'PASS: descriptor-pinned parent replacement\n'

toggle_root="$TEST_ROOT/toggle-parent"
mkdir -p -m 700 "$toggle_root/state/toggles" "$toggle_root/replacement"
touch "$toggle_root/state/toggles/safe"
ready="$toggle_root/ready"
release="$toggle_root/release"
result="$toggle_root/result"
env OMACHORD_FS_TEST_MATCH="$toggle_root/state/toggles" OMACHORD_FS_TEST_PAUSE=before-scan \
  OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
  "$HELPER" list-toggles "$toggle_root/state/toggles" 4096 524288 >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "toggle listing did not reach its parent-swap window"
mv "$toggle_root/state/toggles" "$toggle_root/pinned-toggles"
mv "$toggle_root/replacement" "$toggle_root/state/toggles"
touch "$toggle_root/state/toggles/unsafe"
touch "$release"
if wait "$pid"; then fail "toggle listing accepted a replaced directory"; fi
grep -Fq 'parent-changed' "$result" || fail "toggle parent replacement returned the wrong error"
printf 'PASS: descriptor-pinned toggle listing\n'

durable="$TEST_ROOT/durable"
mkdir -m 700 "$durable"
printf '%s' baseline \
  | "$HELPER" atomic-write "$durable/value" 600 private "$durable/archive" >/dev/null
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"

result="$durable/file-sync.result"
if printf '%s' candidate \
    | env OMACHORD_FS_TEST_MATCH="$durable/value" OMACHORD_FS_TEST_FAIL_SYNC=1 \
        "$HELPER" cas-write "$durable/value" 600 "$baseline" private "$durable/archive" >"$result"; then
  fail "filesystem helper reported success after a staged-file sync failure"
fi
grep -Fq 'durability-error' "$result" || fail "file sync failure returned the wrong error"
[[ $(cat "$durable/value") == baseline ]] || fail "file sync failure changed the destination"
assert_no_transaction_files "$durable"

result="$durable/directory-sync.result"
if printf '%s' candidate \
    | env OMACHORD_FS_TEST_MATCH="$durable/value" OMACHORD_FS_TEST_FAIL_SYNC=3 \
        "$HELPER" cas-write "$durable/value" 600 "$baseline" private "$durable/archive" >"$result"; then
  fail "filesystem helper reported success after a directory sync failure"
fi
grep -Fq 'durability-error' "$result" || fail "directory sync failure returned the wrong error"
[[ $(cat "$durable/value") == baseline ]] || fail "directory sync failure was not rolled back"
assert_no_transaction_files "$durable"
printf 'PASS: durable atomic publication\n'

post_commit="$TEST_ROOT/post-commit"
mkdir -m 700 "$post_commit"
printf '%s' baseline >"$post_commit/value"
chmod 600 "$post_commit/value"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
if ! printf '%s' candidate \
    | env OMACHORD_FS_TEST_MATCH="$post_commit/value" OMACHORD_FS_TEST_FAIL_SYNC=4 \
        "$HELPER" cas-write "$post_commit/value" 600 "$baseline" private "$post_commit/archive" >/dev/null; then
  fail "post-commit cleanup failure made a durable write ambiguous"
fi
[[ $(cat "$post_commit/value") == candidate ]] || fail "post-commit write did not retain the candidate"
printf 'PASS: non-failing post-commit cleanup\n'

for ordinal in 1 2 3 4; do
  remove_root="$TEST_ROOT/remove-sync-$ordinal"
  mkdir -p -m 700 "$remove_root/archive/retired"
  printf '%s' baseline >"$remove_root/value"
  chmod 600 "$remove_root/value"
  baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
  result="$remove_root/result"
  if env OMACHORD_FS_TEST_MATCH="$remove_root/value" OMACHORD_FS_TEST_FAIL_SYNC="$ordinal" \
      "$HELPER" cas-remove "$remove_root/value" "$baseline" private "$remove_root/archive" >"$result"; then
    [[ ! -e $remove_root/value ]] \
      || fail "successful removal sync phase $ordinal retained the destination"
  else
    [[ -f $remove_root/value && $(cat "$remove_root/value") == baseline ]] \
      || fail "failed removal sync phase $ordinal did not restore the destination"
  fi
  assert_no_transaction_files "$remove_root"
done
printf 'PASS: exception-safe durable removal\n'

for operation in cas-write cas-remove; do
  recovery="$TEST_ROOT/$operation-exchange-recovery"
  mkdir -m 700 "$recovery"
  printf '%s' baseline >"$recovery/value"
  chmod 600 "$recovery/value"
  baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
  ready="$recovery/ready"
  release="$recovery/release"
  result="$recovery/result"
  if [[ $operation == cas-write ]]; then
    printf '%s' candidate \
      | env OMACHORD_FS_TEST_MATCH="$recovery/value" OMACHORD_FS_TEST_PAUSE=before-exchange \
          OMACHORD_FS_TEST_READY="$ready" \
          OMACHORD_FS_TEST_RELEASE="$release" \
          "$HELPER" cas-write "$recovery/value" 600 "$baseline" private "$recovery/archive" >"$result" &
  else
    env OMACHORD_FS_TEST_MATCH="$recovery/value" OMACHORD_FS_TEST_PAUSE=before-exchange \
      OMACHORD_FS_TEST_READY="$ready" \
      OMACHORD_FS_TEST_RELEASE="$release" \
      "$HELPER" cas-remove "$recovery/value" "$baseline" private "$recovery/archive" >"$result" &
  fi
  pid=$!
  for _ in {1..500}; do
    [[ -e $ready ]] && break
    sleep 0.01
  done
  [[ -e $ready ]] || fail "$operation did not reach its exchange recovery window"
  printf '%s' concurrent >"$recovery/value"
  touch "$release"
  if wait "$pid"; then fail "$operation accepted content changed before exchange"; fi
  [[ $(cat "$recovery/value") == concurrent ]] \
    || fail "$operation lost the concurrent version after a compare mismatch"
  assert_no_transaction_files "$recovery"
done
printf 'PASS: compare-mismatch recovery\n'

replacement="$TEST_ROOT/post-publish-replacement"
mkdir -m 700 "$replacement"
printf '%s' baseline >"$replacement/value"
printf '%s' concurrent >"$replacement/newer"
chmod 600 "$replacement/value" "$replacement/newer"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
ready="$replacement/ready"
release="$replacement/release"
result="$replacement/result"
printf '%s' candidate \
  | env OMACHORD_FS_TEST_MATCH="$replacement/value" OMACHORD_FS_TEST_PAUSE=after-exchange \
      OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
      "$HELPER" cas-write "$replacement/value" 600 "$baseline" private "$replacement/archive" >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "CAS write did not reach its post-publication window"
mv -fT -- "$replacement/newer" "$replacement/value"
touch "$release"
if wait "$pid"; then fail "CAS write accepted a post-publication replacement"; fi
[[ $(cat "$replacement/value") == concurrent ]] \
  || fail "CAS rollback overwrote a newer destination"
assert_no_transaction_files "$replacement"

for ordinal in 2 4; do
  unstable="$TEST_ROOT/unstable-fingerprint-$ordinal"
  mkdir -m 700 "$unstable"
  printf '%s' baseline >"$unstable/value"
  chmod 600 "$unstable/value"
  baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
  result="$unstable/result"
  if printf '%s' candidate \
      | env OMACHORD_FS_TEST_MATCH="$unstable/value" \
          OMACHORD_FS_TEST_FAIL_FINGERPRINT="$ordinal" \
          "$HELPER" cas-write "$unstable/value" 600 "$baseline" private "$unstable/archive" >"$result"; then
    fail "CAS write accepted forced fingerprint failure $ordinal"
  fi
  [[ $(cat "$unstable/value") == baseline ]] \
    || fail "fingerprint failure $ordinal left the candidate published"
  assert_no_transaction_files "$unstable"
done

modified_placeholder="$TEST_ROOT/modified-placeholder"
mkdir -m 700 "$modified_placeholder"
printf '%s' baseline >"$modified_placeholder/value"
chmod 600 "$modified_placeholder/value"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
ready="$modified_placeholder/ready"
release="$modified_placeholder/release"
result="$modified_placeholder/result"
env OMACHORD_FS_TEST_MATCH="$modified_placeholder/value" OMACHORD_FS_TEST_PAUSE=after-exchange \
  OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
  "$HELPER" cas-remove "$modified_placeholder/value" "$baseline" private \
    "$modified_placeholder/archive" >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "CAS removal did not publish its placeholder"
printf '%s' concurrent >"$modified_placeholder/value"
touch "$release"
if wait "$pid"; then fail "CAS removal accepted a modified placeholder"; fi
[[ $(cat "$modified_placeholder/value") == concurrent ]] \
  || fail "removal recovery discarded an in-place concurrent write"
find "$modified_placeholder/archive/conflicts" -type f -exec grep -Flx baseline {} + | grep -q . \
  || fail "removal recovery did not preserve the displaced baseline"
assert_no_transaction_files "$modified_placeholder"
printf 'PASS: post-publication concurrent-write recovery\n'

rollback_failure="$TEST_ROOT/explicit-rollback-failure"
mkdir -m 700 "$rollback_failure"
printf '%s' baseline >"$rollback_failure/value"
chmod 600 "$rollback_failure/value"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
ready="$TEST_ROOT/explicit-rollback-ready"
release="$TEST_ROOT/explicit-rollback-release"
result="$rollback_failure/result"
printf '%s' candidate \
  | env OMACHORD_FS_TEST_MATCH="$rollback_failure/value" \
      OMACHORD_FS_TEST_PAUSE=after-exchange OMACHORD_FS_TEST_FAIL_FINGERPRINT=4 \
      OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
      "$HELPER" cas-write "$rollback_failure/value" 600 "$baseline" private \
        "$rollback_failure/archive" >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "CAS write did not reach its forced rollback-failure window"
chmod 500 "$rollback_failure"
touch "$release"
if wait "$pid"; then fail "CAS write reported success when rollback was impossible"; fi
chmod 700 "$rollback_failure"
jq -e '.code == "rollback-failed" and (.preserved | type == "string")' "$result" >/dev/null \
  || fail "failed rollback did not report its state explicitly"
[[ $(cat "$rollback_failure/value") == candidate ]] \
  || fail "rollback-failure test did not retain the reported candidate"
preserved=$(jq -r .preserved "$result")
[[ -f $preserved && $(cat "$preserved") == baseline ]] \
  || fail "failed rollback did not retain the displaced baseline"
printf 'PASS: explicit rollback-failure reporting\n'

open_placeholder="$TEST_ROOT/open-placeholder"
mkdir -p -m 700 "$open_placeholder/archive/retired"
printf '%s' baseline >"$open_placeholder/value"
chmod 600 "$open_placeholder/value"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
ready="$open_placeholder/ready"
release="$open_placeholder/release"
result="$open_placeholder/result"
env OMACHORD_FS_TEST_MATCH="$open_placeholder/value" OMACHORD_FS_TEST_PAUSE=after-exchange \
  OMACHORD_FS_TEST_READY="$ready" OMACHORD_FS_TEST_RELEASE="$release" \
  "$HELPER" cas-remove "$open_placeholder/value" "$baseline" private \
    "$open_placeholder/archive" >"$result" &
pid=$!
for _ in {1..500}; do
  [[ -e $ready ]] && break
  sleep 0.01
done
[[ -e $ready ]] || fail "CAS removal did not expose its placeholder for open-FD testing"
exec 8>>"$open_placeholder/value"
touch "$release"
wait "$pid" || fail "open placeholder prevented a committed removal"
printf '%s' late-placeholder-write >&8
exec 8>&-
find "$open_placeholder/archive/retired" -type f -exec grep -Fl late-placeholder-write {} + \
  | grep -q . || fail "post-removal descriptor write was lost"
printf 'PASS: open placeholder inode preservation\n'

owned="$TEST_ROOT/owned-links"
mkdir -m 755 "$owned"
printf '%s' baseline >"$owned/value"
chmod 644 "$owned/value"
ln "$owned/value" "$owned/other-link"
baseline="file:644:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
printf '%s' candidate \
  | "$HELPER" cas-write "$owned/value" 644 "$baseline" owned "$TEST_ROOT/owned-archive" >/dev/null
[[ $(cat "$owned/value") == candidate && $(cat "$owned/other-link") == baseline ]] \
  || fail "owned-policy write mishandled an existing hard link"

uncertain="$TEST_ROOT/uncertain-open-state"
mkdir -p -m 700 "$uncertain/archive/retired"
printf '%s' baseline >"$uncertain/value"
chmod 600 "$uncertain/value"
baseline="file:600:$(printf '%s' baseline | sha256sum | awk '{print $1}')"
printf '%s' candidate \
  | OMACHORD_FS_TEST_FAIL_FUSER=1 "$HELPER" cas-write "$uncertain/value" 600 \
      "$baseline" private "$uncertain/archive" >/dev/null
find "$uncertain/archive/retired" -type f -exec grep -Flx baseline {} + | grep -q . \
  || fail "an uncertain open-inode check discarded the replaced inode"
printf 'PASS: owned links and fail-closed inode preservation\n'

prepared_state="$TEST_ROOT/prepared-state"
"$HELPER" prepare-state "$prepared_state" fallback-runtime
[[ $(stat -c %a "$prepared_state") == 700 ]] \
  || fail "prepare-state did not create a private state directory"
for name in config.lock log.lock runs.jsonl connection.json connection.disabled.json \
    config.commit.json bar-widget.json backups conflicts retired active runtime; do
  [[ ! -e $prepared_state/$name ]] \
    || fail "prepare-state created optional state entry $name"
done

state_files=(config.lock log.lock runs.jsonl connection.json connection.disabled.json \
  config.commit.json bar-widget.json)
state_directories=(backups conflicts retired active)
touch "${state_files[@]/#/$prepared_state/}"
mkdir "${state_directories[@]/#/$prepared_state/}" "$prepared_state/runtime"
chmod 755 "$prepared_state"
chmod 644 "${state_files[@]/#/$prepared_state/}"
chmod 755 "${state_directories[@]/#/$prepared_state/}" "$prepared_state/runtime"
"$HELPER" prepare-state "$prepared_state"
[[ $(stat -c %a "$prepared_state") == 700 ]] \
  || fail "prepare-state did not repair the state-directory mode"
for name in "${state_files[@]}"; do
  [[ $(stat -c %a "$prepared_state/$name") == 600 ]] \
    || fail "prepare-state did not repair private-file mode for $name"
done
for name in "${state_directories[@]}"; do
  [[ $(stat -c %a "$prepared_state/$name") == 700 ]] \
    || fail "prepare-state did not repair private-directory mode for $name"
done
[[ $(stat -c %a "$prepared_state/runtime") == 755 ]] \
  || fail "prepare-state secured a non-fallback runtime directory"
"$HELPER" prepare-state "$prepared_state" fallback-runtime
[[ $(stat -c %a "$prepared_state/runtime") == 700 ]] \
  || fail "prepare-state did not secure the fallback runtime directory"

state_sentinel="$TEST_ROOT/prepare-state-sentinel"
printf '%s' sentinel >"$state_sentinel"
chmod 640 "$state_sentinel"
rm -f "$prepared_state/config.lock"
ln -s "$state_sentinel" "$prepared_state/config.lock"
if "$HELPER" prepare-state "$prepared_state" >/dev/null 2>&1; then
  fail "prepare-state accepted a symlinked optional file"
fi
[[ $(stat -c %a "$state_sentinel") == 640 && $(cat "$state_sentinel") == sentinel ]] \
  || fail "prepare-state changed a symlink target"
rm -f "$prepared_state/config.lock"

rm -rf "$prepared_state/backups"
ln -s "$state_sentinel" "$prepared_state/backups"
if "$HELPER" prepare-state "$prepared_state" >/dev/null 2>&1; then
  fail "prepare-state accepted a symlinked optional directory"
fi
[[ $(stat -c %a "$state_sentinel") == 640 ]] \
  || fail "prepare-state changed an optional-directory symlink target"
rm -f "$prepared_state/backups"

rm -f "$prepared_state/runs.jsonl"
mkfifo "$prepared_state/runs.jsonl"
chmod 600 "$prepared_state/runs.jsonl"
start=$(date +%s%3N)
if "$HELPER" prepare-state "$prepared_state" >/dev/null 2>&1; then
  fail "prepare-state accepted a FIFO optional file"
fi
elapsed=$(($(date +%s%3N) - start))
((elapsed < 1000)) || fail "prepare-state blocked on a FIFO for ${elapsed}ms"
rm -f "$prepared_state/runs.jsonl"
printf 'PASS: batched private-state preparation\n'

unique="$TEST_ROOT/unique"
mkdir -m 700 "$unique"
result="$unique/result"
if printf '%s' backup \
    | env OMACHORD_FS_TEST_MATCH="$unique" OMACHORD_FS_TEST_FAIL_SYNC=2 \
        "$HELPER" unique-write "$unique" backup. 600 >"$result"; then
  fail "unique write reported success after its directory sync failed"
fi
if find "$unique" -maxdepth 1 -type f -name 'backup.*' -print -quit | grep -q .; then
  fail "failed unique write leaked an unreported backup"
fi
printf 'PASS: unique-write failure cleanup\n'

printf 'Filesystem helper tests passed.\n'
