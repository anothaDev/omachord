#!/bin/bash

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

"$ROOT/test/version-test.sh"
python3 "$ROOT/test/production-instrumentation-test.py"
"$ROOT/test/fs-helper-test.sh"
python3 "$ROOT/test/fs-recovery-test.py"
"$ROOT/test/action-supervisor-test.sh"
python3 "$ROOT/test/action-capture-test.py"
python3 "$ROOT/test/action-cancellation-test.py"
"$ROOT/test/runner-test.sh"
"$ROOT/test/authorization-test.sh"
"$ROOT/test/manual-revision-test.sh"
python3 "$ROOT/test/automatic-trigger-test.py"
python3 "$ROOT/test/runner-parsing-staging-test.py"
python3 "$ROOT/test/panel-capture-test.py"
"$ROOT/test/runner-speed-test.sh"
"$ROOT/test/qml-runtime-test.sh"
bash "$ROOT/test/qml-bar-test.sh"
"$ROOT/test/qml-service-test.sh"
python3 "$ROOT/test/qml-service-watchers-test.py"
python3 "$ROOT/test/qml-routine-id-test.py"
"$ROOT/test/qml-panel-enable-test.sh"
"$ROOT/test/qml-manual-revision-test.sh"
"$ROOT/test/qml-panel-connection-test.sh"
"$ROOT/test/qml-toggle-test.sh"
python3 "$ROOT/test/qml-theme-palette-test.py"
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
  "$ROOT/PendingSwitch.qml" \
  "$ROOT/PendingToggle.qml" \
  "$ROOT/ChoicePicker.qml" \
  "$ROOT/RoutineEditor.qml" \
  "$ROOT/ActionCard.qml" \
  "$ROOT/Service.qml" \
  "$ROOT/ShortcutRecorder.qml" \
  "$ROOT/BarWidget.qml" \
  "$ROOT/BrandIcon.qml" \
  "$ROOT/RoutinePopup.qml" \
  "$ROOT/ThemePalette.qml" \
  "$ROOT/KeyCap.qml" \
  "$ROOT/EmptyState.qml" \
  "$ROOT/Collapsible.qml"

printf 'All tests passed.\n'
