#!/usr/bin/env bash
# Keep the demo sidecar entrypoint byte-identical to the core copy.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
core="${CONTROLS_CORE:-../controls-core}/deploy/sidecar/entrypoint.sh"
if [ ! -f "$core" ]; then
  echo "entrypoint-check: missing $core; set CONTROLS_CORE" >&2
  exit 1
fi
if ! cmp -s sidecar/entrypoint.sh "$core"; then
  echo "entrypoint-check: sidecar/entrypoint.sh differs from $core" >&2
  exit 1
fi
echo "entrypoint-check OK: demo entrypoint matches controls-core"
