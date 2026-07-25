#!/usr/bin/env bash
# Print the Seerr API key Boxarr expects for Sonarr/Radarr emulation.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/show-seerr-key.sh | sudo bash

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

DB="/DATA/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

[[ -f "${DB}" ]] || { echo "FAIL: boxarr.db not found at ${DB}"; exit 1; }

KEY="$(sqlite3 "${DB}" "SELECT value FROM settings WHERE key='seerr.api_keys' LIMIT 1;" 2>/dev/null || true)"

echo "=== Seerr API key (for Sonarr + Radarr in Seerr) ==="
if [[ -n "${KEY}" ]]; then
  echo "${KEY}"
else
  echo "(not set — open Boxarr → Settings → Requests → Generate)"
fi
echo
echo "Seerr → Settings → Services:"
echo
echo "  Option 1 (hostname + port + URL base):"
echo "    Sonarr: host boxarr  port 8080  URL base /sonarr"
echo "    Radarr: host boxarr  port 8080  URL base /radarr"
echo
echo "  Option 2 (full URL, if your Seerr version supports it):"
echo "    Sonarr: http://boxarr:8080/sonarr"
echo "    Radarr: http://boxarr:8080/radarr"
echo
echo "Full guide: https://github.com/killamfkr/warpbox/tree/boxarr-zimaos/docs/seerr-setup.md"
