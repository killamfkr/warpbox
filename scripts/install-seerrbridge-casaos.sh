#!/usr/bin/env bash
# SeerrBridge one-shot installer for CasaOS / ZimaOS.
#
# SeerrBridge connects Seerr/Overseerr/Jellyseerr → Debrid Media Manager → Real-Debrid.
# Official compatibility: Real-Debrid only (TorBox is NOT supported by SeerrBridge).
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/mainlink0435/warpbox/main/scripts/install-seerrbridge-casaos.sh | sudo bash
#
# Optional env vars:
#   SEERRBRIDGE_INSTALL_DIR  default: /opt/seerrbridge
#   SEERRBRIDGE_DATA_DIR     default: /DATA/AppData/seerrbridge
#   SEERRBRIDGE_DASHBOARD_PORT default: 3777
#   SEERRBRIDGE_WEBHOOK_PORT   default: 8777
#   SEERR_DOCKER_NETWORK     optional: attach to Seerr container network (e.g. big-bear-seerr)

set -euo pipefail

SEERRBRIDGE_INSTALL_DIR="${SEERRBRIDGE_INSTALL_DIR:-/opt/seerrbridge}"
SEERRBRIDGE_DATA_DIR="${SEERRBRIDGE_DATA_DIR:-/DATA/AppData/seerrbridge}"
SEERRBRIDGE_IMAGE="${SEERRBRIDGE_IMAGE:-ghcr.io/woahai321/seerrbridge:latest}"
SEERRBRIDGE_DASHBOARD_PORT="${SEERRBRIDGE_DASHBOARD_PORT:-3777}"
SEERRBRIDGE_WEBHOOK_PORT="${SEERRBRIDGE_WEBHOOK_PORT:-8777}"
SEERRBRIDGE_SETUP_PORT="${SEERRBRIDGE_SETUP_PORT:-8778}"
SEERRBRIDGE_MYSQL_PORT="${SEERRBRIDGE_MYSQL_PORT:-3307}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-seerrbridge_root}"
DB_NAME="${DB_NAME:-seerrbridge}"
DB_USER="${DB_USER:-seerrbridge}"
DB_PASSWORD="${DB_PASSWORD:-seerrbridge}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "error: run as root (prefix with sudo)" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "error: docker compose plugin not found" >&2
  exit 1
fi

detect_host_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

HOST_IP="$(detect_host_ip)"
HOST_IP="${HOST_IP:-<your-nas-ip>}"

echo "==> SeerrBridge installer (CasaOS / ZimaOS)"
echo "    install: ${SEERRBRIDGE_INSTALL_DIR}"
echo "    data:    ${SEERRBRIDGE_DATA_DIR}"
echo "    image:   ${SEERRBRIDGE_IMAGE}"

mkdir -p "${SEERRBRIDGE_INSTALL_DIR}" "${SEERRBRIDGE_DATA_DIR}/data" "${SEERRBRIDGE_DATA_DIR}/logs"

NETWORK_BLOCK=""
if [[ -n "${SEERR_DOCKER_NETWORK:-}" ]]; then
  if docker network inspect "${SEERR_DOCKER_NETWORK}" >/dev/null 2>&1; then
    NETWORK_BLOCK="    networks:
      - seerr_net"
    echo "    network: ${SEERR_DOCKER_NETWORK}"
  else
    echo "warning: network ${SEERR_DOCKER_NETWORK} not found — skipping network attach" >&2
    SEERR_DOCKER_NETWORK=""
  fi
fi

cat > "${SEERRBRIDGE_INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  seerrbridge:
    image: ${SEERRBRIDGE_IMAGE}
    container_name: seerrbridge
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      DB_HOST: localhost
      DB_PORT: 3306
      DB_NAME: ${DB_NAME}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}
      USE_DATABASE: "true"
      PYTHONUNBUFFERED: "1"
      PYTHONDONTWRITEBYTECODE: "1"
      NODE_ENV: production
      NUXT_HOST: 0.0.0.0
      NUXT_PORT: 3777
      SEERRBRIDGE_URL: http://localhost:8777
      SETUP_API_URL: http://localhost:8778
      SEERRBRIDGE_SETUP_URL: http://localhost:8778
    ports:
      - "${SEERRBRIDGE_MYSQL_PORT}:3306"
      - "${SEERRBRIDGE_DASHBOARD_PORT}:3777"
      - "${SEERRBRIDGE_WEBHOOK_PORT}:8777"
      - "${SEERRBRIDGE_SETUP_PORT}:8778"
    volumes:
      - seerrbridge_mysql_data:/var/lib/mysql
      - ${SEERRBRIDGE_DATA_DIR}/logs:/app/logs
      - ${SEERRBRIDGE_DATA_DIR}/data:/app/data
    healthcheck:
      test: ["CMD", "sh", "-c", "curl -f http://localhost:8777/status && curl -f http://localhost:3777/api/health || exit 1"]
      timeout: 10s
      retries: 5
      interval: 30s
      start_period: 120s
${NETWORK_BLOCK}

volumes:
  seerrbridge_mysql_data:
    name: seerrbridge_mysql_data
EOF

if [[ -n "${SEERR_DOCKER_NETWORK:-}" ]]; then
  cat >> "${SEERRBRIDGE_INSTALL_DIR}/docker-compose.yml" <<EOF

networks:
  seerr_net:
    external: true
    name: ${SEERR_DOCKER_NETWORK}
EOF
fi

echo "==> Pulling image and starting SeerrBridge"
docker compose -f "${SEERRBRIDGE_INSTALL_DIR}/docker-compose.yml" pull
docker compose -f "${SEERRBRIDGE_INSTALL_DIR}/docker-compose.yml" up -d

echo "==> Waiting for dashboard (up to 3 minutes on first start)"
ready=0
for _ in $(seq 1 36); do
  if curl -fsS "http://127.0.0.1:${SEERRBRIDGE_DASHBOARD_PORT}/api/health" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 5
done

WEBHOOK_HOST="${SEERR_WEBHOOK_HOST:-}"
if [[ -z "${WEBHOOK_HOST}" ]]; then
  if [[ -n "${SEERR_DOCKER_NETWORK:-}" ]]; then
    WEBHOOK_HOST="http://seerrbridge:${SEERRBRIDGE_WEBHOOK_PORT}/jellyseer-webhook/"
  else
    WEBHOOK_HOST="http://${HOST_IP}:${SEERRBRIDGE_WEBHOOK_PORT}/jellyseer-webhook/"
  fi
fi

cat <<EOF

============================================================
 SeerrBridge is running
============================================================

 Dashboard:  http://${HOST_IP}:${SEERRBRIDGE_DASHBOARD_PORT}/

 Configure in the dashboard (required):
   1. Real-Debrid tokens (from DMM browser local storage)
   2. Seerr/Overseerr API key
   3. Trakt client ID (optional but recommended)

 Seerr webhook URL (Settings → Notifications → Webhook):
   ${WEBHOOK_HOST}

 Enable notification type:
   "Request Automatically Approved"

 IMPORTANT — debrid service support:
   SeerrBridge officially supports Real-Debrid only.
   TorBox is NOT supported. If you use Warpbox + TorBox, add
   content via Debrid Media Manager manually instead.

 Full stack with Warpbox + Plex:
   Seerr → SeerrBridge → DMM → Real-Debrid → (separate from TorBox)
   OR skip SeerrBridge and use DMM + TorBox directly with Warpbox.

 Manage:
   cd ${SEERRBRIDGE_INSTALL_DIR}
   docker compose ps
   docker compose logs -f seerrbridge
   docker compose restart
   docker compose down

 Data persists in:
   ${SEERRBRIDGE_DATA_DIR}/data
   ${SEERRBRIDGE_DATA_DIR}/logs
   docker volume seerrbridge_mysql_data
============================================================
EOF

if [[ "${ready}" -eq 0 ]]; then
  echo "warning: dashboard not healthy yet — first boot can take 2+ minutes."
  echo "  docker logs -f seerrbridge"
fi
