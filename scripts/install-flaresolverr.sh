#!/usr/bin/env bash
# Add FlareSolverr to an existing Boxarr stack (compose + Prowlarr proxy config).
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
INSTALL_DIR="/DATA/AppData/boxarr-stack"
COMPOSE="${INSTALL_DIR}/docker-compose.yml"
TZ="${TZ:-Etc/UTC}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  INSTALL_DIR="/media/Storage/AppData/boxarr-stack"
  COMPOSE="${INSTALL_DIR}/docker-compose.yml"
fi

[[ -f "${COMPOSE}" ]] || die "compose not found at ${COMPOSE} — run install.sh first"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${COMPOSE}" "$@"; }
else
  DC() { docker-compose -f "${COMPOSE}" "$@"; }
fi

if ! grep -q 'container_name: flaresolverr' "${COMPOSE}" 2>/dev/null \
  && ! grep -q 'flaresolverr:' "${COMPOSE}" 2>/dev/null; then
  say "Adding flaresolverr service to docker-compose.yml"
  python3 - "${COMPOSE}" "${TZ}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
tz = sys.argv[2]
text = path.read_text()
if "flaresolverr:" in text:
    sys.exit(0)
block = f"""
  flaresolverr:
    image: flaresolverr/flaresolverr
    container_name: flaresolverr
    restart: unless-stopped
    environment:
      LOG_LEVEL: info
      TZ: "{tz}"
      CAPTCHA_SOLVER: none
    ports:
      - "8191:8191"
    networks:
      - boxarr-net
"""
marker = "\nnetworks:"
if marker not in text:
    die_msg = "could not find networks: block in compose"
    raise SystemExit(die_msg)
path.write_text(text.replace(marker, block + marker, 1))
print(f"patched {path}")
PY
else
  ok "flaresolverr already in compose"
fi

docker rm -f flaresolverr 2>/dev/null || true

say "Starting FlareSolverr"
DC pull flaresolverr 2>/dev/null || true
DC up -d flaresolverr

CFG="${SCRIPT_DIR}/configure-prowlarr-flaresolverr.sh"
if [[ ! -f "${CFG}" ]]; then
  curl -fsSL "${RAW_BASE}/configure-prowlarr-flaresolverr.sh" -o /tmp/configure-prowlarr-flaresolverr.sh
  CFG="/tmp/configure-prowlarr-flaresolverr.sh"
fi
chmod +x "${CFG}"
bash "${CFG}"

ok "FlareSolverr running — Prowlarr proxy configured"
echo "  container: flaresolverr"
echo "  host:      http://flaresolverr:8191"
echo "  tag:       flaresolverr (add to Cloudflare indexers in Prowlarr)"
