#!/usr/bin/env bash
# Clear stale Boxarr TorBox cooldown when torbox.app no longer shows one.
# Boxarr caches torbox.cooldown_until in SQLite after 429s or account cooldown reads.
#
# Run on ZimaOS:
#   sudo bash clear-boxarr-cooldown.sh
#   sudo bash clear-boxarr-cooldown.sh --force   # clear without checking TorBox API

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

[[ -f "${DB}" ]] || { echo "FAIL: boxarr.db not found at ${DB}"; exit 1; }

KEY="$(sqlite3 "${DB}" "SELECT value FROM settings WHERE key='torbox.token' LIMIT 1;" 2>/dev/null || true)"
CACHED="$(sqlite3 "${DB}" "SELECT value FROM settings WHERE key='torbox.cooldown_until' LIMIT 1;" 2>/dev/null || true)"

echo "=== Boxarr TorBox cooldown ==="
echo "db: ${DB}"
if [[ -n "${CACHED}" ]]; then
  echo "boxarr cached cooldown_until: ${CACHED}"
else
  echo "boxarr cached cooldown_until: (none)"
fi
echo

TB_COOLDOWN=""
if [[ -n "${KEY}" ]] && [[ "${FORCE}" -eq 0 ]]; then
  echo "=== TorBox account (GET /user/me) ==="
  ME="$(curl -sf -H "Authorization: Bearer ${KEY}" \
    "https://api.torbox.app/v1/api/user/me?settings=false" 2>&1)" || {
    echo "WARN: could not reach TorBox API — use --force to clear Boxarr cache anyway"
    ME=""
  }
  if [[ -n "${ME}" ]]; then
    TB_COOLDOWN="$(echo "${ME}" | python3 -c "
import json, sys
d = json.load(sys.stdin).get('data', {})
print(d.get('cooldown_until') or '')
" 2>/dev/null || true)"
    echo "torbox cooldown_until: ${TB_COOLDOWN:-"(none)"}"
  fi
  echo
elif [[ -z "${KEY}" ]]; then
  echo "WARN: no torbox.token in Boxarr DB — cannot compare with TorBox API"
  echo
fi

if [[ -z "${CACHED}" ]]; then
  echo "OK: Boxarr has no cached cooldown. Nothing to clear."
  exit 0
fi

if [[ "${FORCE}" -eq 0 ]] && [[ -n "${TB_COOLDOWN}" ]]; then
  echo "FAIL: TorBox still reports cooldown_until=${TB_COOLDOWN}"
  echo "     Wait for TorBox to clear it, or check torbox.app dashboard."
  exit 1
fi

if [[ "${FORCE}" -eq 0 ]] && [[ -z "${TB_COOLDOWN}" ]] && [[ -n "${KEY}" ]]; then
  echo "Mismatch: TorBox has no cooldown but Boxarr still does — clearing stale cache."
elif [[ "${FORCE}" -eq 1 ]]; then
  echo "Force: clearing Boxarr torbox.cooldown_until"
else
  echo "Clearing Boxarr torbox.cooldown_until (TorBox API not checked)."
fi

sqlite3 "${DB}" "DELETE FROM settings WHERE key='torbox.cooldown_until';"
echo "deleted torbox.cooldown_until from settings"

if docker ps --format '{{.Names}}' | grep -qx boxarr; then
  docker restart boxarr >/dev/null
  echo "restarted boxarr"
else
  echo "boxarr container not running — restart it manually when ready"
fi

echo
echo "OK: Boxarr cooldown cleared. Try a grab again (prefer TPB over YTS)."
