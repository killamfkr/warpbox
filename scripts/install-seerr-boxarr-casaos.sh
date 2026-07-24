#!/usr/bin/env bash
# Seerr + Boxarr + Prowlarr one-shot installer for CasaOS / ZimaOS.
#
# Standalone TorBox request stack — own rclone WebDAV mount, no Warpbox required.
#
# One-liner (interactive):
#   curl -fsSL https://raw.githubusercontent.com/mainlink0435/warpbox/main/scripts/install-seerr-boxarr-casaos.sh | sudo bash
#
# One-liner (non-interactive):
#   curl -fsSL https://raw.githubusercontent.com/mainlink0435/warpbox/main/scripts/install-seerr-boxarr-casaos.sh | sudo TORBOX_API_KEY='...' TMDB_API_KEY='...' bash
#
# Optional env vars:
#   BOXARR_INSTALL_DIR       default: /DATA/AppData/boxarr-stack
#   BOXARR_DATA_ROOT         default: /DATA/AppData
#   BOXARR_MEDIA_ROOT        default: /DATA/Media
#   BOXARR_PUID / BOXARR_PGID default: first non-root user or 1000
#   BOXARR_SEERR_API_KEY     auto-generated if unset
#   PROWLARR_API_KEY         extracted from Prowlarr after first boot if unset

set -euo pipefail

BOXARR_INSTALL_DIR="${BOXARR_INSTALL_DIR:-/DATA/AppData/boxarr-stack}"
BOXARR_DATA_ROOT="${BOXARR_DATA_ROOT:-/DATA/AppData}"
BOXARR_MEDIA_ROOT="${BOXARR_MEDIA_ROOT:-/DATA/Media}"
BOXARR_IMAGE="${BOXARR_IMAGE:-ghcr.io/radaiko/boxarr:latest}"
SEERR_IMAGE="${SEERR_IMAGE:-ghcr.io/seerr-team/seerr:latest}"
PROWLARR_IMAGE="${PROWLARR_IMAGE:-lscr.io/linuxserver/prowlarr:latest}"
RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone:latest}"

BOXARR_PORT="${BOXARR_PORT:-8181}"
SEERR_PORT="${SEERR_PORT:-5055}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"

BOXARR_APPDATA="${BOXARR_DATA_ROOT}/boxarr"
RCLONE_APPDATA="${BOXARR_DATA_ROOT}/boxarr-rclone"
PROWLARR_APPDATA="${BOXARR_DATA_ROOT}/prowlarr"
SEERR_APPDATA="${BOXARR_DATA_ROOT}/seerr"

TORBOX_MOUNT="${BOXARR_MEDIA_ROOT}/torbox"
LIBRARY_ROOT="${BOXARR_MEDIA_ROOT}/library"
TZ="${TZ:-Etc/UTC}"

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "error: run as root (prefix with sudo)" >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found" >&2
  exit 1
fi

DOCKER=(docker)
COMPOSE=(docker compose)
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    echo "error: docker compose plugin not found" >&2
    exit 1
  fi
fi

if ! "${DOCKER[@]}" info >/dev/null 2>&1; then
  echo "error: cannot talk to docker — try: sudo docker ps" >&2
  exit 1
fi

dc() { "${COMPOSE[@]}" -f "${BOXARR_INSTALL_DIR}/docker-compose.yml" "$@"; }

if [[ ! -e /dev/fuse ]]; then
  echo "error: /dev/fuse missing — FUSE is required for the TorBox rclone mount" >&2
  exit 1
fi

detect_ids() {
  local uid gid user
  user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  uid="$(id -u "${user}" 2>/dev/null || true)"
  gid="$(id -g "${user}" 2>/dev/null || true)"
  if [[ -z "${uid}" || "${uid}" == "0" ]]; then
    uid=1000
    gid=1000
  fi
  echo "${uid} ${gid}"
}

read -r BOXARR_PUID BOXARR_PGID < <(detect_ids)
BOXARR_PUID="${BOXARR_PUID:-1000}"
BOXARR_PGID="${BOXARR_PGID:-1000}"

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-<your-nas-ip>}"

if [[ -z "${BOXARR_SEERR_API_KEY:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    BOXARR_SEERR_API_KEY="$(openssl rand -hex 16)"
  else
    BOXARR_SEERR_API_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  fi
fi

echo "==> Seerr + Boxarr installer (CasaOS / ZimaOS)"
echo "    install:  ${BOXARR_INSTALL_DIR}"
echo "    library:  ${LIBRARY_ROOT}"
echo "    mount:    ${TORBOX_MOUNT}"
echo "    puid:     ${BOXARR_PUID}  pgid: ${BOXARR_PGID}"

if [[ -z "${TORBOX_API_KEY:-}" ]]; then
  echo
  read -r -p "TorBox API key: " TORBOX_API_KEY
  echo
fi
if [[ -z "${TORBOX_API_KEY:-}" ]]; then
  echo "error: TORBOX_API_KEY is required" >&2
  exit 1
fi

if [[ -z "${TMDB_API_KEY:-}" ]]; then
  echo "TMDB Read Access Token (v4) from themoviedb.org → Settings → API"
  read -r -p "TMDB API key: " TMDB_API_KEY
  echo
fi
if [[ -z "${TMDB_API_KEY:-}" ]]; then
  echo "error: TMDB_API_KEY is required for Boxarr" >&2
  exit 1
fi

echo "==> Creating directories"
mkdir -p \
  "${BOXARR_INSTALL_DIR}" \
  "${BOXARR_APPDATA}" \
  "${RCLONE_APPDATA}/cache" \
  "${PROWLARR_APPDATA}" \
  "${SEERR_APPDATA}" \
  "${TORBOX_MOUNT}" \
  "${LIBRARY_ROOT}/movies" \
  "${LIBRARY_ROOT}/tv" \
  "${LIBRARY_ROOT}/anime"
chown -R "${BOXARR_PUID}:${BOXARR_PGID}" \
  "${BOXARR_APPDATA}" "${RCLONE_APPDATA}" "${PROWLARR_APPDATA}" \
  "${SEERR_APPDATA}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}" 2>/dev/null || true

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

echo "==> Configuring shared mount propagation for ${TORBOX_MOUNT}"
mount --bind "${TORBOX_MOUNT}" "${TORBOX_MOUNT}" 2>/dev/null || true
mount --make-rshared "${TORBOX_MOUNT}" 2>/dev/null || true

cat > "${RCLONE_APPDATA}/rclone.conf" <<EOF
[torbox]
type = webdav
url = https://webdav.torbox.app/
vendor = other
user = torbox
pass = ${TORBOX_API_KEY}
EOF
chmod 600 "${RCLONE_APPDATA}/rclone.conf"
chown "${BOXARR_PUID}:${BOXARR_PGID}" "${RCLONE_APPDATA}/rclone.conf" 2>/dev/null || true

cat > "${BOXARR_INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  boxarr:
    image: ${BOXARR_IMAGE}
    container_name: boxarr
    restart: unless-stopped
    user: "${BOXARR_PUID}:${BOXARR_PGID}"
    environment:
      - BOXARR_DATABASE_PATH=/config/boxarr.db
      - BOXARR_LISTEN_ADDR=:8080
      - TZ=${TZ}
      - BOXARR_TORBOX_API_TOKEN=${TORBOX_API_KEY}
      - BOXARR_PROWLARR_URL=http://boxarr-prowlarr:9696
      - BOXARR_PROWLARR_API_KEY=__PROWLARR_API_KEY__
      - BOXARR_TMDB_API_KEY=${TMDB_API_KEY}
      - BOXARR_SEERR_API_KEYS=${BOXARR_SEERR_API_KEY}
      - BOXARR_WEBDAV_MOUNT_ROOT=/mnt/torbox
      - BOXARR_MOVIE_LIBRARY_ROOT=/mnt/library/movies
      - BOXARR_TV_LIBRARY_ROOT=/mnt/library/tv
      - BOXARR_ANIME_LIBRARY_ROOT=/mnt/library/anime
    ports:
      - "${BOXARR_PORT}:8080"
    volumes:
      - ${BOXARR_APPDATA}:/config
      - ${LIBRARY_ROOT}:/mnt/library
      - type: bind
        source: ${TORBOX_MOUNT}
        target: /mnt/torbox
        bind:
          propagation: rslave
    depends_on:
      - boxarr-rclone
    networks: [boxarr-media]
    healthcheck:
      test: ["CMD", "/boxarr", "healthcheck"]
      interval: 60s
      timeout: 5s
      retries: 3

  boxarr-rclone:
    image: ${RCLONE_IMAGE}
    container_name: boxarr-rclone
    restart: unless-stopped
    cap_add: [SYS_ADMIN]
    devices: ["/dev/fuse:/dev/fuse:rwm"]
    security_opt: ["apparmor:unconfined"]
    environment:
      - TZ=${TZ}
    volumes:
      - ${RCLONE_APPDATA}/rclone.conf:/config/rclone/rclone.conf:ro
      - ${RCLONE_APPDATA}/cache:/cache
      - /etc/fuse.conf:/etc/fuse.conf:ro
      - type: bind
        source: ${TORBOX_MOUNT}
        target: /data
        bind:
          propagation: rshared
    command:
      - mount
      - torbox:
      - /data
      - --allow-other
      - --allow-non-empty
      - --dir-cache-time
      - 1h
      - --vfs-cache-mode
      - full
      - --vfs-cache-max-size
      - 50G
      - --vfs-cache-max-age
      - 168h
      - --vfs-read-ahead
      - 256M
      - --vfs-read-chunk-size
      - 32M
      - --vfs-read-chunk-size-limit
      - 1G
      - --buffer-size
      - 64M
      - --vfs-fast-fingerprint
      - --no-checksum
      - --no-modtime
      - --transfers
      - "4"
      - --checkers
      - "2"
      - --tpslimit
      - "5"
      - --tpslimit-burst
      - "5"
      - --low-level-retries
      - "3"
      - --attr-timeout
      - 24h
      - --umask
      - "002"
      - --uid
      - "${BOXARR_PUID}"
      - --gid
      - "${BOXARR_PGID}"
      - --cache-dir
      - /cache
      - --log-level
      - INFO
    networks: [boxarr-media]

  prowlarr:
    image: ${PROWLARR_IMAGE}
    container_name: boxarr-prowlarr
    restart: unless-stopped
    environment:
      - PUID=${BOXARR_PUID}
      - PGID=${BOXARR_PGID}
      - TZ=${TZ}
    volumes:
      - ${PROWLARR_APPDATA}:/config
    ports:
      - "${PROWLARR_PORT}:9696"
    networks: [boxarr-media]

  seerr:
    image: ${SEERR_IMAGE}
    container_name: boxarr-seerr
    init: true
    restart: unless-stopped
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
      - PORT=5055
    volumes:
      - ${SEERR_APPDATA}:/app/config
    ports:
      - "${SEERR_PORT}:5055"
    networks: [boxarr-media]

networks:
  boxarr-media:
    name: boxarr-media
    driver: bridge
EOF

chmod 755 "${BOXARR_INSTALL_DIR}"
chmod 644 "${BOXARR_INSTALL_DIR}/docker-compose.yml"

echo "==> Starting Prowlarr (needed for Boxarr search)"
dc pull
dc up -d boxarr-prowlarr

PROWLARR_CONFIG="${PROWLARR_APPDATA}/config.xml"
echo "==> Waiting for Prowlarr API key"
if [[ -z "${PROWLARR_API_KEY:-}" ]]; then
  for _ in $(seq 1 60); do
    if [[ -f "${PROWLARR_CONFIG}" ]]; then
      PROWLARR_API_KEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_CONFIG}" | head -1)"
      if [[ -n "${PROWLARR_API_KEY}" ]]; then
        break
      fi
    fi
    sleep 2
  done
fi

if [[ -z "${PROWLARR_API_KEY:-}" ]]; then
  echo "warning: could not read Prowlarr API key yet — set it later in Boxarr Settings" >&2
  PROWLARR_API_KEY=""
fi

sed -i "s|__PROWLARR_API_KEY__|${PROWLARR_API_KEY}|" "${BOXARR_INSTALL_DIR}/docker-compose.yml"

echo "==> Starting full stack"
dc up -d

echo "==> Waiting for Boxarr"
for _ in $(seq 1 36); do
  if curl -fsS "http://127.0.0.1:${BOXARR_PORT}/" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

cat <<EOF

============================================================
 Seerr + Boxarr stack is running
============================================================

 Seerr (requests):     http://${HOST_IP}:${SEERR_PORT}/
 Boxarr (manager):     http://${HOST_IP}:${BOXARR_PORT}/
 Prowlarr (indexers):  http://${HOST_IP}:${PROWLARR_PORT}/

 TorBox mount:         ${TORBOX_MOUNT}
 Plex symlinks:        ${LIBRARY_ROOT}

 Seerr API key (for Boxarr ↔ Seerr):
   ${BOXARR_SEERR_API_KEY}

── One-time Seerr setup ────────────────────────────────────
 1. Open Seerr → complete wizard → connect Plex
 2. Settings → Services → Sonarr:
      URL:    http://boxarr:8080/sonarr
      API key: ${BOXARR_SEERR_API_KEY}
 3. Settings → Services → Radarr:
      URL:    http://boxarr:8080/radarr
      API key: ${BOXARR_SEERR_API_KEY}
 4. Set default quality profile + root folder for each

── Prowlarr (required) ─────────────────────────────────────
 1. Open Prowlarr → Indexers → add your indexers
 2. Boxarr searches via Prowlarr — no indexers = no grabs

── Plex bind mounts (both paths required) ───────────────────
   ${LIBRARY_ROOT}  →  /mnt/library
   ${TORBOX_MOUNT}  →  /mnt/torbox

 Plex libraries:
   Movies → /mnt/library/movies
   TV     → /mnt/library/tv
   Anime  → /mnt/library/anime

── Permissions ───────────────────────────────────────────────
 All services use uid:gid ${BOXARR_PUID}:${BOXARR_PGID}.
 Match Plex PUID/PGID to the same values if playback fails.

 Diagnose problems:
   sudo bash ${BOXARR_INSTALL_DIR}/diagnose.sh

 Manage:
   cd ${BOXARR_INSTALL_DIR}
   sudo docker compose ps
   sudo docker compose logs -f boxarr-rclone
   sudo docker compose restart
============================================================
EOF
