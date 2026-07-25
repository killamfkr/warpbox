#!/usr/bin/env bash
# Start Prowlarr torrent proxy for Boxarr (fixes indexerIds=-1 usenet-only searches).
# Run as root on ZimaOS after boxarr-prowlarr is up.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-prowlarr-proxy.sh -o /tmp/p.sh && sed -i 's/\r$//' /tmp/p.sh && chmod +x /tmp/p.sh && sudo bash /tmp/p.sh

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
PROWLARR_UPSTREAM="${PROWLARR_UPSTREAM:-http://boxarr-prowlarr:9696}"
PROXY_PORT="${PROWLARR_PROXY_PORT:-9697}"
PROXY_DIR="${BASE}/AppData/boxarr-prowlarr-proxy"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  BASE="/media/Storage"
  PROXY_DIR="${BASE}/AppData/boxarr-prowlarr-proxy"
fi

mkdir -p "${PROXY_DIR}"
RAW_BASE="${BOXARR_ZIMAOS_RAW:-https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts}"
curl -fsSL "${RAW_BASE}/prowlarr-torrent-proxy.py" \
  -o "${PROXY_DIR}/prowlarr-torrent-proxy.py"

docker rm -f boxarr-prowlarr-proxy 2>/dev/null || true
docker ps -a --format '{{.Names}}' | grep -E '^boxarr-prowlarr-proxy' | xargs -r docker rm -f 2>/dev/null || true
systemctl disable --now boxarr-prowlarr-proxy 2>/dev/null || true

# Use boxarr-net so Boxarr container can reach the proxy by name
NET="boxarr-net"
docker network inspect "${NET}" >/dev/null 2>&1 || NET="bridge"

docker run -d \
  --name boxarr-prowlarr-proxy \
  --restart unless-stopped \
  --network "${NET}" \
  -e "PROWLARR_UPSTREAM=${PROWLARR_UPSTREAM}" \
  -e "PROWLARR_PROXY_PORT=${PROXY_PORT}" \
  -e "SANITIZE_MAGNETS=0" \
  -v "${PROXY_DIR}/prowlarr-torrent-proxy.py:/app/prowlarr-torrent-proxy.py:ro" \
  python:3-alpine \
  python3 /app/prowlarr-torrent-proxy.py

sleep 2
PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${BASE}/AppData/prowlarr/config.xml" 2>/dev/null | head -1 || true)"
if [[ -n "${PKEY}" ]]; then
  docker run --rm --network "${NET}" curlimages/curl:latest \
    -sf -H "X-Api-Key: ${PKEY}" "http://boxarr-prowlarr-proxy:${PROXY_PORT}/api/v1/indexer" >/dev/null \
    || { docker logs boxarr-prowlarr-proxy --tail 10; exit 1; }
fi

echo "OK: boxarr-prowlarr-proxy running on ${NET}:${PROXY_PORT}"
echo "     mode: rewrite-only (indexerIds -1 → -2, magnets untouched)"
echo
echo "In Boxarr → Settings → Prowlarr → Server URL, set:"
echo "  http://boxarr-prowlarr-proxy:${PROXY_PORT}"
echo
echo "To remove the proxy entirely: disable-prowlarr-proxy.sh"
echo "Save, then retry Search releases."
