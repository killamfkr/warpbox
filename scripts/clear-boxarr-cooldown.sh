#!/usr/bin/env bash
# Back-compat wrapper — use clear-boxarr-pause.sh for full diagnostics.
# Run on ZimaOS:
#   sudo bash clear-boxarr-cooldown.sh
#   sudo bash clear-boxarr-cooldown.sh --force

set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${DIR}/clear-boxarr-pause.sh" "$@"
