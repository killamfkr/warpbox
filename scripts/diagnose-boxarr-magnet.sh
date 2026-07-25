#!/usr/bin/env bash
# Diagnose TorBox "invalid magnet link" failures in Boxarr stacks.
# Run on ZimaOS:
#   sudo bash diagnose-boxarr-magnet.sh

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

echo "=== Boxarr magnet / TorBox submit diagnostics ==="
echo

echo "=== 1. Prowlarr torrent proxy (required) ==="
if docker ps --format '{{.Names}}' | grep -qx boxarr-prowlarr-proxy; then
  echo "OK  boxarr-prowlarr-proxy running"
else
  echo "FAIL boxarr-prowlarr-proxy not running"
  echo "     Install: install-prowlarr-proxy.sh"
fi

if [[ -f "${DB}" ]]; then
  PROWLARR_URL="$(sqlite3 "${DB}" "SELECT value FROM settings WHERE key='prowlarr.url' LIMIT 1;" 2>/dev/null || true)"
  echo "boxarr prowlarr.url: ${PROWLARR_URL:-"(not set)"}"
  case "${PROWLARR_URL:-}" in
    *boxarr-prowlarr-proxy:9697*) echo "OK  Boxarr points at torrent proxy" ;;
    *9696*) echo "WARN Boxarr points at raw Prowlarr :9696 — should be http://boxarr-prowlarr-proxy:9697" ;;
    "") echo "WARN set Boxarr → Settings → Prowlarr → http://boxarr-prowlarr-proxy:9697" ;;
    *) echo "WARN unexpected Prowlarr URL — expected http://boxarr-prowlarr-proxy:9697" ;;
  esac
fi
echo

echo "=== 2. Recent failed torrent jobs ==="
if [[ -f "${DB}" ]]; then
  sqlite3 -header -column "${DB}" \
    "SELECT id, substr(nzb_name,1,45) AS release, substr(fail_message,1,100) AS error
     FROM jobs WHERE protocol='torrent' AND state='failed'
     ORDER BY id DESC LIMIT 8;" 2>/dev/null || true
  INVALID_COUNT="$(sqlite3 "${DB}" \
    "SELECT COUNT(*) FROM jobs WHERE protocol='torrent' AND state='failed'
     AND fail_message LIKE '%magnet%';" 2>/dev/null || echo 0)"
  echo "failed jobs mentioning magnet: ${INVALID_COUNT}"
else
  echo "boxarr.db not found"
fi
echo

echo "=== 3. Last submitted torrent magnet (what TorBox saw) ==="
if [[ -f "${DB}" ]]; then
  sqlite3 "${DB}" \
    "SELECT substr(torrent_magnet,1,120) FROM jobs
     WHERE protocol='torrent' AND torrent_magnet IS NOT NULL AND torrent_magnet != ''
     ORDER BY id DESC LIMIT 1;" 2>/dev/null | sed 's/^/magnet: /' || echo "(none)"
fi
echo

echo "=== 4. TorBox account + test submit ==="
if [[ -f "${DB}" ]]; then
  RAW_BASE="${BOXARR_ZIMAOS_RAW:-https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts}"
  if [[ -f "$(dirname "$0")/test-torbox-submit.sh" ]]; then
    bash "$(dirname "$0")/test-torbox-submit.sh" || true
  else
    curl -fsSL "${RAW_BASE}/test-torbox-submit.sh" | bash || true
  fi
fi
echo

echo "=== 5. Indexer advice ==="
cat <<'EOF'
TorBox "invalid magnet link" is almost always bad indexer data, not your account.

Fix (in order):
  1. Reinstall the magnet-sanitizing proxy:
       sudo bash install-prowlarr-proxy.sh
  2. In Boxarr → Settings → Prowlarr, set URL to:
       http://boxarr-prowlarr-proxy:9697
  3. In Prowlarr → Indexers:
       - Enable The Pirate Bay (TPB)
       - Disable YTS / YIFY (their magnets often fail on TorBox)
  4. Clear failed jobs and retry from Boxarr (or delete failed job + search again)
  5. When searching releases in Boxarr, pick a TPB result, not YTS

The proxy strips YTS magnets so Boxarr fetches the .torrent file instead.
EOF
