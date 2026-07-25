#!/usr/bin/env bash
# Start FlareSolverr for Prowlarr (docker run — does NOT edit docker-compose.yml).
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-flaresolverr.sh -o /tmp/install-flaresolverr.sh
# sudo bash /tmp/install-flaresolverr.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

RAW_BASE="${BOXARR_ZIMAOS_RAW:-https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE="/DATA/AppData/boxarr-stack/docker-compose.yml"
TZ="${TZ:-Etc/UTC}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  COMPOSE="/media/Storage/AppData/boxarr-stack/docker-compose.yml"
fi

# If a previous run broke compose, restore backup first
if [[ -f "${COMPOSE}" ]]; then
  if ! docker compose -f "${COMPOSE}" config >/dev/null 2>&1 \
    && ! docker-compose -f "${COMPOSE}" config >/dev/null 2>&1; then
    say "docker-compose.yml is invalid — restoring backup"
    REPAIR="${SCRIPT_DIR}/repair-compose.sh"
    if [[ ! -f "${REPAIR}" ]]; then
      curl -fsSL "${RAW_BASE}/repair-compose.sh" -o /tmp/repair-compose.sh
      REPAIR="/tmp/repair-compose.sh"
    fi
    chmod +x "${REPAIR}"
    bash "${REPAIR}" || die "repair-compose.sh failed — fix ${COMPOSE} manually"
  fi
fi

docker network inspect boxarr-net >/dev/null 2>&1 || docker network create boxarr-net

say "Removing old FlareSolverr container"
docker rm -f flaresolverr 2>/dev/null || true

say "Starting FlareSolverr (docker run — compose file not modified)"
docker run -d \
  --name flaresolverr \
  --restart unless-stopped \
  --network boxarr-net \
  -e LOG_LEVEL=info \
  -e "TZ=${TZ}" \
  -e CAPTCHA_SOLVER=none \
  -p 8191:8191 \
  flaresolverr/flaresolverr

say "Waiting for FlareSolverr"
for _ in $(seq 1 30); do
  if docker run --rm --network boxarr-net curlimages/curl:latest -sf http://flaresolverr:8191/ >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

CFG="${SCRIPT_DIR}/configure-prowlarr-flaresolverr.sh"
if [[ ! -f "${CFG}" ]]; then
  curl -fsSL "${RAW_BASE}/configure-prowlarr-flaresolverr.sh" -o /tmp/configure-prowlarr-flaresolverr.sh
  CFG="/tmp/configure-prowlarr-flaresolverr.sh"
fi
chmod +x "${CFG}"
bash "${CFG}"

ok "FlareSolverr running"
echo "  container: flaresolverr"
echo "  url:       http://flaresolverr:8191"
echo "  tag:       flaresolverr (add on Cloudflare indexers in Prowlarr)"
echo
echo "Verify: sudo docker ps | grep flaresolverr"
