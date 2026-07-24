#!/usr/bin/env bash
# Boxarr + rclone + Prowlarr installer for CasaOS / ZimaOS.
# Optional Seerr (set INSTALL_SEERR=0 to skip).
#
# RECOMMENDED one-liner (download first — works on CasaOS web terminal):
#   curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-casaos.sh -o /tmp/install-boxarr.sh && sed -i 's/\r$//' /tmp/install-boxarr.sh && chmod +x /tmp/install-boxarr.sh && sudo /tmp/install-boxarr.sh
#
# With API keys (no prompts):
#   curl -fsSL ... -o /tmp/install-boxarr.sh && sed -i 's/\r$//' /tmp/install-boxarr.sh && chmod +x /tmp/install-boxarr.sh && sudo TORBOX_API_KEY='key' TMDB_API_KEY='key' /tmp/install-boxarr.sh
#
# Optional env:
#   INSTALL_SEERR=0          skip Seerr container
#   BOXARR_PUID / BOXARR_PGID  default: Plex container uid or 1000

set -euo pipefail

INSTALL_DIR="/DATA/AppData/boxarr-stack"
BOXARR_APPDATA="/DATA/AppData/boxarr"
RCLONE_APPDATA="/DATA/AppData/boxarr-rclone"
PROWLARR_APPDATA="/DATA/AppData/prowlarr"
SEERR_APPDATA="/DATA/AppData/seerr"
TORBOX_MOUNT="/DATA/Media/torbox"
LIBRARY_ROOT="/DATA/Media/library"
TZ="${TZ:-Etc/UTC}"
INSTALL_SEERR="${INSTALL_SEERR:-1}"
SEERR_UID="${SEERR_UID:-1000}"
SEERR_GID="${SEERR_GID:-1000}"

BOXARR_PORT="${BOXARR_PORT:-8181}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
SEERR_PORT="${SEERR_PORT:-5055}"

die() { echo "error: $*" >&2; exit 1; }

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  die "run as root: sudo /tmp/install-boxarr.sh"
fi

command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -e /dev/fuse ]] || die "/dev/fuse missing — FUSE required for rclone"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  die "docker compose not found"
fi

docker info >/dev/null 2>&1 || die "cannot access docker — is the daemon running?"

detect_puid() {
  local uid gid
  if docker ps --format '{{.Names}}' | grep -qi plex; then
    uid="$(docker exec plex id -u 2>/dev/null || true)"
    gid="$(docker exec plex id -g 2>/dev/null || true)"
  fi
  if [[ -z "${uid}" || "${uid}" == "0" ]]; then
    local user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
    uid="$(id -u "${user}" 2>/dev/null || echo 1000)"
    gid="$(id -g "${user}" 2>/dev/null || echo 1000)"
  fi
  echo "${uid} ${gid}"
}

read -r BOXARR_PUID BOXARR_PGID < <(detect_puid)
BOXARR_PUID="${BOXARR_PUID:-1000}"
BOXARR_PGID="${BOXARR_PGID:-1000}"

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
HOST_IP="${HOST_IP:-localhost}"

BOXARR_SEERR_API_KEY="${BOXARR_SEERR_API_KEY:-$(openssl rand -hex 16 2>/dev/null || head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"

echo "==> Boxarr stack installer"
echo "    dir:   ${INSTALL_DIR}"
echo "    puid:  ${BOXARR_PUID}:${BOXARR_PGID} (matched to Plex if found)"
echo "    mount: ${TORBOX_MOUNT}"
echo "    libs:  ${LIBRARY_ROOT}"

if [[ -z "${TORBOX_API_KEY:-}" ]]; then
  read -r -p "TorBox API key: " TORBOX_API_KEY
fi
[[ -n "${TORBOX_API_KEY:-}" ]] || die "TORBOX_API_KEY required"

if [[ -z "${TMDB_API_KEY:-}" ]]; then
  read -r -p "TMDB API key (v4 read token): " TMDB_API_KEY
fi
[[ -n "${TMDB_API_KEY:-}" ]] || die "TMDB_API_KEY required"

echo "==> Creating directories"
mkdir -p \
  "${INSTALL_DIR}" \
  "${BOXARR_APPDATA}" \
  "${RCLONE_APPDATA}/cache" \
  "${PROWLARR_APPDATA}" \
  "${SEERR_APPDATA}" \
  "${TORBOX_MOUNT}" \
  "${LIBRARY_ROOT}/movies" \
  "${LIBRARY_ROOT}/tv" \
  "${LIBRARY_ROOT}/anime"

echo "==> Setting permissions (${BOXARR_PUID}:${BOXARR_PGID})"
chown -R "${BOXARR_PUID}:${BOXARR_PGID}" \
  "${BOXARR_APPDATA}" \
  "${RCLONE_APPDATA}" \
  "${PROWLARR_APPDATA}" \
  "${TORBOX_MOUNT}" \
  "${LIBRARY_ROOT}"
chown -R "${SEERR_UID}:${SEERR_GID}" "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${LIBRARY_ROOT}" "${TORBOX_MOUNT}" "${RCLONE_APPDATA}" "${SEERR_APPDATA}"

FUSE_CONF="/etc/fuse.conf"
if [[ -f "${FUSE_CONF}" ]]; then
  grep -q '^user_allow_other' "${FUSE_CONF}" || \
    sed -i 's/^#user_allow_other/user_allow_other/' "${FUSE_CONF}" 2>/dev/null || \
    echo "user_allow_other" >> "${FUSE_CONF}"
else
  echo "user_allow_other" > "${FUSE_CONF}"
fi

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
chown "${BOXARR_PUID}:${BOXARR_PGID}" "${RCLONE_APPDATA}/rclone.conf"

SEERR_BLOCK=""
if [[ "${INSTALL_SEERR}" == "1" ]]; then
  SEERR_BLOCK="
  boxarr-seerr:
    image: ghcr.io/seerr-team/seerr:latest
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
      - \"${SEERR_PORT}:5055\"
    networks: [boxarr-media]"
fi

cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  boxarr:
    image: ghcr.io/radaiko/boxarr:latest
    container_name: boxarr
    restart: unless-stopped
    user: "${BOXARR_PUID}:${BOXARR_PGID}"
    environment:
      - BOXARR_DATABASE_PATH=/config/boxarr.db
      - BOXARR_LISTEN_ADDR=:8080
      - TZ=${TZ}
      - BOXARR_TORBOX_API_TOKEN=${TORBOX_API_KEY}
      - BOXARR_PROWLARR_URL=http://boxarr-prowlarr:9696
      - BOXARR_PROWLARR_API_KEY=__PROWLARR_KEY__
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

  boxarr-rclone:
    image: rclone/rclone:latest
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

  boxarr-prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
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
${SEERR_BLOCK}

networks:
  boxarr-media:
    name: boxarr-media
    driver: bridge
EOF

chmod 755 "${INSTALL_DIR}"
chmod 644 "${INSTALL_DIR}/docker-compose.yml"
chown root:root "${INSTALL_DIR}/docker-compose.yml"

cat > "${INSTALL_DIR}/start.sh" <<'EOS'
#!/bin/bash
cd /DATA/AppData/boxarr-stack
docker compose up -d "$@"
EOS
chmod 755 "${INSTALL_DIR}/start.sh"

echo "==> Pulling images"
DC pull

echo "==> Starting Prowlarr"
DC up -d boxarr-prowlarr

PROWLARR_KEY=""
for _ in $(seq 1 60); do
  if [[ -f "${PROWLARR_APPDATA}/config.xml" ]]; then
    PROWLARR_KEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_APPDATA}/config.xml" | head -1)"
    [[ -n "${PROWLARR_KEY}" ]] && break
  fi
  sleep 2
done

sed -i "s|__PROWLARR_KEY__|${PROWLARR_KEY}|" "${INSTALL_DIR}/docker-compose.yml"

echo "==> Starting stack"
chown -R "${SEERR_UID}:${SEERR_GID}" "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${SEERR_APPDATA}"
DC up -d

sleep 5
echo "==> Status"
DC ps

echo
echo "============================================================"
echo " Boxarr stack installed"
echo "============================================================"
echo " Boxarr:    http://${HOST_IP}:${BOXARR_PORT}/"
echo " Prowlarr:  http://${HOST_IP}:${PROWLARR_PORT}/"
if [[ "${INSTALL_SEERR}" == "1" ]]; then
  echo " Seerr:     http://${HOST_IP}:${SEERR_PORT}/"
  echo " Seerr key: ${BOXARR_SEERR_API_KEY}"
fi
echo
echo " Plex bind mounts (add in Plex app Settings → Volumes):"
echo "   ${LIBRARY_ROOT}  ->  /mnt/library"
echo "   ${TORBOX_MOUNT}  ->  /mnt/torbox"
echo
echo " Plex libraries: /mnt/library/movies  /mnt/library/tv"
echo " Prowlarr: add indexers first, then use Boxarr"
echo " UID/GID:  ${BOXARR_PUID}:${BOXARR_PGID} (set LinuxServer Plex PUID/PGID to match)"
echo
echo " Manage:  cd ${INSTALL_DIR} && docker compose ps"
echo " Logs:    docker logs boxarr-rclone --tail 30"
echo "============================================================"

if ! docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  echo "warning: boxarr-rclone not running — check: docker logs boxarr-rclone" >&2
fi
