#!/usr/bin/env bash
# Warpbox one-shot installer for CasaOS / ZimaOS (Plex-ready).
#
# One-liner (interactive — prompts for TorBox API key):
#   curl -fsSL https://raw.githubusercontent.com/mainlink0435/warpbox/main/scripts/install-casaos-zimaos.sh | sudo bash
#
# One-liner (non-interactive):
#   curl -fsSL https://raw.githubusercontent.com/mainlink0435/warpbox/main/scripts/install-casaos-zimaos.sh | sudo TORBOX_API_KEY='your-key' bash
#
# Optional env vars:
#   WARPBOX_DATA_DIR   default: /DATA/AppData/warpbox
#   WARPBOX_MOUNT_DIR  default: /DATA/Media/warpbox
#   WARPBOX_CACHE_DIR  default: /DATA/AppData/rclone-cache
#   WARPBOX_INSTALL_DIR default: /opt/warpbox
#   WARPBOX_PUID       default: first non-root user or 1000
#   WARPBOX_PGID       default: same as PUID

set -euo pipefail

WARPBOX_DATA_DIR="${WARPBOX_DATA_DIR:-/DATA/AppData/warpbox}"
WARPBOX_MOUNT_DIR="${WARPBOX_MOUNT_DIR:-/DATA/Media/warpbox}"
WARPBOX_CACHE_DIR="${WARPBOX_CACHE_DIR:-/DATA/AppData/rclone-cache}"
WARPBOX_INSTALL_DIR="${WARPBOX_INSTALL_DIR:-/opt/warpbox}"
WARPBOX_IMAGE="${WARPBOX_IMAGE:-ghcr.io/mainlink0435/warpbox:latest}"
WARPBOX_PORT="${WARPBOX_PORT:-1412}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "error: run as root (prefix with sudo)" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found — install Docker first" >&2
  exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "error: docker compose plugin not found" >&2
  exit 1
fi

if [[ ! -e /dev/fuse ]]; then
  echo "error: /dev/fuse missing — FUSE is required for the rclone mount" >&2
  exit 1
fi

detect_ids() {
  local uid gid
  uid="$(id -u "${SUDO_USER:-$(logname 2>/dev/null || echo "")}" 2>/dev/null || true)"
  gid="$(id -g "${SUDO_USER:-$(logname 2>/dev/null || echo "")}" 2>/dev/null || true)"
  if [[ -z "${uid}" || "${uid}" == "0" ]]; then
    uid=1000
    gid=1000
  fi
  echo "${uid} ${gid}"
}

read -r WARPBOX_PUID WARPBOX_PGID < <(detect_ids)
WARPBOX_PUID="${WARPBOX_PUID:-1000}"
WARPBOX_PGID="${WARPBOX_PGID:-1000}"

echo "==> Warpbox installer (CasaOS / ZimaOS)"
echo "    data:   ${WARPBOX_DATA_DIR}"
echo "    mount:  ${WARPBOX_MOUNT_DIR}"
echo "    cache:  ${WARPBOX_CACHE_DIR}"
echo "    puid:   ${WARPBOX_PUID}  pgid: ${WARPBOX_PGID}"

echo "==> Creating directories"
mkdir -p "${WARPBOX_DATA_DIR}" "${WARPBOX_MOUNT_DIR}" "${WARPBOX_CACHE_DIR}" "${WARPBOX_INSTALL_DIR}"
chown -R "${WARPBOX_PUID}:${WARPBOX_PGID}" "${WARPBOX_DATA_DIR}" "${WARPBOX_MOUNT_DIR}" "${WARPBOX_CACHE_DIR}" 2>/dev/null || true

echo "==> Enabling FUSE user_allow_other"
FUSE_CONF="/etc/fuse.conf"
if [[ -f "${FUSE_CONF}" ]]; then
  if grep -q '^#user_allow_other' "${FUSE_CONF}"; then
    sed -i 's/^#user_allow_other/user_allow_other/' "${FUSE_CONF}"
  elif ! grep -q '^user_allow_other' "${FUSE_CONF}"; then
    echo "user_allow_other" >> "${FUSE_CONF}"
  fi
else
  echo "user_allow_other" > "${FUSE_CONF}"
fi

echo "==> Writing ${WARPBOX_INSTALL_DIR}/docker-compose.yml"
cat > "${WARPBOX_INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  warpbox:
    image: ${WARPBOX_IMAGE}
    container_name: warpbox
    ports:
      - "${WARPBOX_PORT}:1412"
    volumes:
      - ${WARPBOX_DATA_DIR}:/data
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:1412/healthz"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

  rclone:
    image: rclone/rclone:latest
    container_name: warpbox-rclone
    restart: unless-stopped
    environment:
      - RCLONE_CONFIG_WARPBOX_TYPE=webdav
      - RCLONE_CONFIG_WARPBOX_URL=http://warpbox:1412/webdav/
      - RCLONE_CONFIG_WARPBOX_VENDOR=other
    volumes:
      - ${WARPBOX_MOUNT_DIR}:/data:rshared
      - ${WARPBOX_CACHE_DIR}:/cache
      - /etc/fuse.conf:/etc/fuse.conf:ro
    cap_add:
      - SYS_ADMIN
    security_opt:
      - apparmor:unconfined
    devices:
      - /dev/fuse:/dev/fuse:rwm
    depends_on:
      - warpbox
    command: >
      mount warpbox: /data
      --uid ${WARPBOX_PUID}
      --gid ${WARPBOX_PGID}
      --cache-dir /cache
      --vfs-cache-mode full
      --vfs-cache-max-age 24h
      --vfs-cache-max-size 100G
      --vfs-cache-min-free-space 20G
      --vfs-read-chunk-size 32M
      --vfs-read-chunk-size-limit 256M
      --vfs-read-ahead 256M
      --buffer-size 128M
      --transfers 2
      --checkers 8
      --timeout 300s
      --contimeout 30s
      --low-level-retries 3
      --dir-cache-time 10m
      --attr-timeout 24h
      --poll-interval 5m
      --no-checksum
      --no-modtime
      --allow-other
      --allow-non-empty
      --vfs-fast-fingerprint
      --ignore-case
      --log-level NOTICE
EOF

echo "==> Pulling images and starting containers"
docker compose -f "${WARPBOX_INSTALL_DIR}/docker-compose.yml" pull
docker compose -f "${WARPBOX_INSTALL_DIR}/docker-compose.yml" up -d

CONFIG_FILE="${WARPBOX_DATA_DIR}/config.yml"
echo "==> Waiting for config at ${CONFIG_FILE}"
for _ in $(seq 1 30); do
  if [[ -f "${CONFIG_FILE}" ]]; then
    break
  fi
  sleep 1
done
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "error: config.yml was not created — check: docker logs warpbox" >&2
  exit 1
fi

if [[ -z "${TORBOX_API_KEY:-}" ]]; then
  echo
  read -r -p "Enter your TorBox API key: " TORBOX_API_KEY
  echo
fi
if [[ -z "${TORBOX_API_KEY}" ]]; then
  echo "error: TorBox API key is required (set TORBOX_API_KEY or enter when prompted)" >&2
  exit 1
fi

echo "==> Saving TorBox API key"
python3 - "${CONFIG_FILE}" "${TORBOX_API_KEY}" <<'PY'
import re, sys
path, key = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    text = f.read()
if not re.search(r'^\s*api_key:\s*".*"\s*$', text, re.M):
    print("error: api_key line not found in config.yml", file=sys.stderr)
    sys.exit(1)
text = re.sub(
    r'^(\s*api_key:\s*")[^"]*(")\s*$',
    lambda m: f'{m.group(1)}{key}{m.group(2)}',
    text,
    count=1,
    flags=re.M,
)
with open(path, "w", encoding="utf-8") as f:
    f.write(text)
PY

echo "==> Restarting warpbox with API key"
docker compose -f "${WARPBOX_INSTALL_DIR}/docker-compose.yml" restart warpbox

echo "==> Waiting for warpbox health"
for _ in $(seq 1 60); do
  if curl -fsS "http://127.0.0.1:${WARPBOX_PORT}/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

echo "==> Waiting for rclone mount (up to 3 minutes)"
mounted=0
for _ in $(seq 1 36); do
  if [[ -d "${WARPBOX_MOUNT_DIR}/__all__" || -d "${WARPBOX_MOUNT_DIR}/movies" ]]; then
    mounted=1
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx warpbox-rclone; then
    echo "warning: warpbox-rclone is not running — check: docker logs warpbox-rclone" >&2
    break
  fi
  sleep 5
done

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-<your-nas-ip>}"

cat <<EOF

============================================================
 Warpbox is ready for Plex
============================================================

 Web UI:     http://${HOST_IP}:${WARPBOX_PORT}/

 Plex movie library folder:  ${WARPBOX_MOUNT_DIR}/movies
 Plex TV library folder:     ${WARPBOX_MOUNT_DIR}/tv
 Everything (unfiltered):    ${WARPBOX_MOUNT_DIR}/__all__

 If Plex runs in Docker, bind-mount the same host path into Plex:
   ${WARPBOX_MOUNT_DIR} -> /mnt/warpbox  (example)

 Plex tips (first run):
   - Disable "Generate video preview thumbnails"
   - Turn OFF "Empty trash automatically after every scan" until stable

 Manage stack:
   cd ${WARPBOX_INSTALL_DIR}
   docker compose ps
   docker compose logs -f warpbox
   docker compose logs -f warpbox-rclone
   docker compose restart
   docker compose down

 Re-run this installer safely — it updates compose and restarts.
============================================================
EOF

if [[ "${mounted}" -eq 0 ]]; then
  echo "warning: mount folders not visible yet. Give it another minute, then run:"
  echo "  ls ${WARPBOX_MOUNT_DIR}"
  echo "  docker logs warpbox-rclone"
  exit 0
fi

ls -la "${WARPBOX_MOUNT_DIR}" 2>/dev/null || true
