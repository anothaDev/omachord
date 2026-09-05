#!/bin/bash

set -euo pipefail

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

omarchy_version=$(omarchy version 2>/dev/null)
omarchy_version=${omarchy_version%%-*}
[[ $omarchy_version == 4.0.2 ]] \
  || fail "expected Omarchy 4.0.2, found ${omarchy_version:-unknown}"

hyprland_version=$(hyprctl version -j 2>/dev/null | jq -er '.version')
[[ $hyprland_version == 0.56.2 ]] \
  || fail "expected Hyprland 0.56.2, found ${hyprland_version:-unknown}"

quickshell_version=$(quickshell --version 2>/dev/null | awk 'NR == 1 {print $2}')
[[ $quickshell_version == 0.3.1 ]] \
  || fail "expected Quickshell 0.3.1, found ${quickshell_version:-unknown}"

printf 'Dependency versions match the v0.4 release target.\n'
