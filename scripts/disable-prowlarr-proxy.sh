#!/usr/bin/env bash
# Remove boxarr-prowlarr-proxy and point Boxarr at Prowlarr directly.
#
# WARNING: Boxarr hardcodes indexerIds=-1 (Usenet) on every search. Prowlarr
# returns HTTP 400 on torrent-only setups unless something rewrites that to -2.
# If searches break after this, either:
#   - re-run install-prowlarr-proxy.sh (rewrite-only, no magnet changes), or
#   - wait for a Boxarr fix upstream
#
# Run on ZimaOS:
#   sudo bash disable-prowlarr-proxy.sh

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

DIRECT_URL="http://boxarr-prowlarr:9696"

echo "=== Disable Prowlarr torrent proxy ==="

docker rm -f boxarr-prowlarr-proxy 2>/dev/null && echo "removed boxarr-prowlarr-proxy" \
  || echo "boxarr-prowlarr-proxy was not running"

if [[ -f "${DB}" ]]; then
  sqlite3 "${DB}" "INSERT INTO settings(key,value) VALUES('prowlarr.url','${DIRECT_URL}')
    ON CONFLICT(key) DO UPDATE SET value='${DIRECT_URL}';"
  echo "boxarr prowlarr.url -> ${DIRECT_URL}"
fi

if docker ps --format '{{.Names}}' | grep -qx boxarr; then
  docker restart boxarr >/dev/null
  echo "restarted boxarr"
fi

echo
echo "Boxarr now talks to Prowlarr directly (no proxy)."
echo "If Search releases returns HTTP 400, Boxarr is still asking for Usenet indexers."
echo "That is a Boxarr limitation — reinstall the minimal proxy:"
echo "  sudo bash install-prowlarr-proxy.sh"
echo
echo "The proxy only rewrites indexerIds=-1 to -2. It does not change magnets"
echo "unless you set SANITIZE_MAGNETS=1 on the container."
