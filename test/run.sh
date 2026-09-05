#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

"$ROOT/test/version-test.sh"
"$ROOT/test/fs-helper-test.sh"
"$ROOT/test/action-supervisor-test.sh"
"$ROOT/test/runner-test.sh"
"$ROOT/test/runner-speed-test.sh"
"$ROOT/test/qml-runtime-test.sh"
"$ROOT/test/qml-service-test.sh"
"$ROOT/test/qml-panel-enable-test.sh"
node "$ROOT/test/model-test.mjs"
node "$ROOT/test/conditions-test.mjs"
node "$ROOT/test/qml-plain-text-test.mjs"
node "$ROOT/test/qml-policy-test.mjs"
bash -n "$ROOT/bin/omachord"
perl -c "$ROOT/bin/omachord-fs"
perl -c "$ROOT/bin/omachord-action-supervisor"
desktop-file-validate "$ROOT/desktop/anothadev.omachord.desktop"
omarchy plugin validate "$ROOT"
QT_QPA_PLATFORM=offscreen qmltestrunner -input "$ROOT/test/qml" -o -,txt
qmllint -I /usr/share/omarchy/shell \
  "$ROOT/Panel.qml" \
  "$ROOT/PanelScrollBar.qml" \
  "$ROOT/PlainTextButton.qml" \
  "$ROOT/ChoicePicker.qml" \
  "$ROOT/RoutineEditor.qml" \
  "$ROOT/ActionCard.qml" \
  "$ROOT/Service.qml" \
  "$ROOT/ShortcutRecorder.qml" \
  "$ROOT/BarWidget.qml" \
  "$ROOT/RoutinePopup.qml" \
  "$ROOT/ThemePalette.qml" \
  "$ROOT/KeyCap.qml" \
  "$ROOT/EmptyState.qml" \
  "$ROOT/Collapsible.qml"

printf 'All tests passed.\n'
