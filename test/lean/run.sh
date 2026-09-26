#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lean_bin=${LEAN:-lean}
if ! command -v "$lean_bin" >/dev/null 2>&1; then
  printf 'Lean is required; install it separately or set LEAN to an existing executable.\n' >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  printf 'Node.js is required for Conditions.js conformance checks.\n' >&2
  exit 1
fi

temp_root=${TMPDIR:-/tmp}
if [[ -z ${TMPDIR:-} && -d /tmp/opencode ]]; then temp_root=/tmp/opencode; fi
output=$(mktemp "$temp_root/omachord-lean.XXXXXX")
trap 'rm -f -- "$output"' EXIT

"$lean_bin" --version
# --run elaborates/checks the proofs before executing the vector generator.
# Keep all diagnostics on failure, but do not flood normal output with vectors.
if ! "$lean_bin" --run "$here/Brightness.lean" >"$output"; then
  cat "$output"
  exit 1
fi
awk '!/^(RETRY|DESCRIPTION) /' "$output"
node "$here/conditions-conformance.mjs" "$output"
