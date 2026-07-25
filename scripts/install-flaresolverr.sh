#!/usr/bin/env bash
# Add FlareSolverr to an existing Boxarr stack (compose + Prowlarr proxy config).
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-flaresolverr.sh -o /tmp/install-flaresolverr.sh
# sudo bash /tmp/install-flaresolverr.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

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

compose_valid() {
  DC config >/dev/null 2>&1
}

patch_compose() {
  python3 - "${COMPOSE}" "${TZ}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
tz = sys.argv[2]
text = path.read_text()

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

# Repair earlier broken patch (flaresolverr inserted under a service "networks:" key)
if re.search(r"(?m)^    networks:\n  flaresolverr:", text):
    text = text.replace(
        "    networks:\n  flaresolverr:",
        "    networks:\n      - boxarr-net\n\n  flaresolverr:",
        1,
    )

# Drop flaresolverr blocks so we can re-insert cleanly
text = re.sub(r"(?ms)^  flaresolverr:\n(?:^    .*\n)*", "", text)

if re.search(r"(?m)^  flaresolverr:", text):
    path.write_text(text)
    print("flaresolverr already present")
    sys.exit(0)

m = re.search(r"(?m)^networks:\s*$", text)
if not m:
    raise SystemExit("could not find top-level networks: block in compose")

text = text[: m.start()] + block + "\n" + text[m.start() :]
path.write_text(text)
print(f"patched {path}")
PY
}

backup_compose() {
  cp -a "${COMPOSE}" "${COMPOSE}.bak.$(date +%s)"
}

say "Repairing / patching docker-compose.yml for FlareSolverr"
backup_compose
patch_compose

if ! compose_valid; then
  warn "compose still invalid — restoring latest backup"
  latest="$(ls -t "${COMPOSE}".bak.* 2>/dev/null | head -1 || true)"
  [[ -n "${latest}" ]] && cp -a "${latest}" "${COMPOSE}"
  say "Starting FlareSolverr via docker run (compose left unchanged)"
  USE_RUN=1
else
  USE_RUN=0
fi

docker rm -f flaresolverr 2>/dev/null || true

say "Starting FlareSolverr"
if compose_valid && grep -q '^  flaresolverr:' "${COMPOSE}"; then
  DC pull flaresolverr 2>/dev/null || true
  DC up -d flaresolverr || {
    warn "compose up failed — falling back to docker run"
    docker run -d \
      --name flaresolverr \
      --restart unless-stopped \
      --network boxarr-net \
      -e LOG_LEVEL=info \
      -e "TZ=${TZ}" \
      -e CAPTCHA_SOLVER=none \
      -p 8191:8191 \
      flaresolverr/flaresolverr
  }
else
  docker network inspect boxarr-net >/dev/null 2>&1 || docker network create boxarr-net
  docker run -d \
    --name flaresolverr \
    --restart unless-stopped \
    --network boxarr-net \
    -e LOG_LEVEL=info \
    -e "TZ=${TZ}" \
    -e CAPTCHA_SOLVER=none \
    -p 8191:8191 \
    flaresolverr/flaresolverr
fi

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
