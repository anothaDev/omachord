#!/bin/bash

# Renders the Omachord panel views, its compact layout, and the bar popup
# offscreen into test/render/out/ for visual review. Reads the live
# configuration through the runner; never writes anything.

set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT="${1:-$ROOT/test/render/out}"
if [[ -d /tmp/opencode ]]; then TEST_TMP=/tmp/opencode; else TEST_TMP=${TMPDIR:-/tmp}; fi
WORK=$(mktemp -d "$TEST_TMP/omachord-render.XXXXXX")
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$OUT"
rm -f -- "$OUT/routines.png" "$OUT/shortcuts.png" "$OUT/activity.png" \
  "$OUT/routines-compact.png" "$OUT/popup.png" "$OUT/popup-empty.png" \
  "$OUT/popup-busy.png" "$OUT/popup-off.png"

ln -s /usr/share/omarchy/shell/Commons "$WORK/Commons"
ln -s /usr/share/omarchy/shell/Ui "$WORK/Ui"
ln -s "$ROOT/assets" "$WORK/assets"
for file in "$ROOT"/*.qml "$ROOT"/*.js; do
  ln -s "$file" "$WORK/$(basename -- "$file")"
done
cp -- "$ROOT/test/render/panel.qml" "$WORK/panel.qml"
cp -- "$ROOT/test/render/popup.qml" "$WORK/popup.qml"

render() {
  local config=$1 marker=$2
  shift 2
  if ! env "$@" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
      timeout 90 quickshell --path "$WORK/$config" --no-color >"$WORK/log.txt" 2>&1; then
    cat "$WORK/log.txt" >&2
    return 1
  fi
  if grep -q 'RENDER_FAIL\|Failed to load\|TypeError\|ReferenceError\|Binding loop detected\|Unable to assign' "$WORK/log.txt" \
      || ! grep -q "$marker" "$WORK/log.txt"; then
    cat "$WORK/log.txt" >&2
    return 1
  fi
}

render panel.qml RENDER_DONE RENDER_OUT="$OUT" RENDER_VIEWS=routines,shortcuts,activity
render panel.qml RENDER_DONE RENDER_OUT="$WORK" RENDER_VIEWS=routines RENDER_W=760 RENDER_H=620
mv -- "$WORK/routines.png" "$OUT/routines-compact.png"
render popup.qml WIDGET_DONE WIDGET_OUT="$OUT/popup.png"
render popup.qml WIDGET_DONE WIDGET_OUT="$OUT/popup-empty.png" WIDGET_EMPTY=1
render popup.qml WIDGET_DONE WIDGET_OUT="$OUT/popup-busy.png" WIDGET_EMPTY=1 WIDGET_BUSY=1
render popup.qml WIDGET_DONE WIDGET_OUT="$OUT/popup-off.png" WIDGET_EMPTY=1 WIDGET_OFF=1

for image in routines.png shortcuts.png activity.png routines-compact.png popup.png popup-empty.png popup-busy.png popup-off.png; do
  [[ -s $OUT/$image ]] || { printf 'Missing render: %s\n' "$image" >&2; exit 1; }
  printf '%s\n' "$image"
done
