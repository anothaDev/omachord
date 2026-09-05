#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
TEST_DIR=$(mktemp -d "$TEST_TMP/omachord-bar-test.XXXXXX")
trap 'rm -rf -- "$TEST_DIR"' EXIT

cp -- "$ROOT/test/qml-runtime/bar.qml" "$TEST_DIR/shell.qml"
ln -s /usr/share/omarchy/shell/Commons "$TEST_DIR/Commons"
mkdir "$TEST_DIR/Ui"
for file in /usr/share/omarchy/shell/Ui/*; do
  [[ ${file##*/} == KeyboardPanel.qml ]] || ln -s "$file" "$TEST_DIR/Ui/${file##*/}"
done
cp -- "$ROOT/test/qml-runtime/KeyboardPanel.qml" "$TEST_DIR/Ui/KeyboardPanel.qml"
for file in BarWidget.qml BrandIcon.qml RoutinePopup.qml ThemePalette.qml Model.js Conditions.js assets; do
  ln -s "$ROOT/$file" "$TEST_DIR/$file"
done

for scale in 1 2; do
  log="$TEST_DIR/runtime-$scale.log"
  if ! QT_QPA_PLATFORM=offscreen QT_SCALE_FACTOR="$scale" \
    timeout 15s quickshell --no-duplicate --path "$TEST_DIR/shell.qml" --no-color >"$log" 2>&1 \
    || ! grep -q OMACHORD_BAR_TEST_PASS "$log" \
    || grep -Eq 'OMACHORD_BAR_TEST_FAIL|Error:|Unable to assign|Binding loop' "$log"; then
    cat "$log" >&2
    printf 'FAIL: QML bar artwork regression at scale %s\n' "$scale" >&2
    exit 1
  fi
done

printf 'Bar artwork, live theme switching, layout and click tests passed at 1x/2x.\n'
