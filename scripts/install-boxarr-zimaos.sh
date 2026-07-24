#!/usr/bin/env bash
# Boxarr + rclone + Prowlarr for ZimaOS (SSH required — web terminal often breaks).
#
# 1. ZimaOS → Settings → enable Developer Mode + SSH
# 2. SSH from your PC:  ssh root@<zima-ip>
# 3. Run this ONE line:
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-zimaos.sh -o /tmp/i.sh && sed -i 's/\r$//' /tmp/i.sh && chmod +x /tmp/i.sh && bash /tmp/i.sh
#
# With keys:
# curl -fsSL ... -o /tmp/i.sh && sed -i 's/\r$//' /tmp/i.sh && chmod +x /tmp/i.sh && TORBOX_API_KEY='key' TMDB_API_KEY='key' bash /tmp/i.sh

set -euo pipefail

INSTALL_DIR="/DATA/AppData/boxarr-stack"
BOXARR_APPDATA="/DATA/AppData/boxarr"
RCLONE_APPDATA="/DATA/AppData/boxarr-rclone"
PROWLARR_APPDATA="/DATA/AppData/prowlarr"
SEERR_APPDATA="/DATA/AppData/seerr"
INSTALL_SEERR="${INSTALL_SEERR:-1}"

# ZimaOS usually uses /DATA; some RAID setups use /media/Storage
if [[ -d /DATA/Media ]]; then
  TORBOX_MOUNT="/DATA/Media/torbox"
  LIBRARY_ROOT="/DATA/Media/library"
elif [[ -d /media/Storage ]]; then
  TORBOX_MOUNT="/media/Storage/Media/torbox"
  LIBRARY_ROOT="/media/Storage/Media/library"
  INSTALL_DIR="/media/Storage/AppData/boxarr-stack"
  BOXARR_APPDATA="/media/Storage/AppData/boxarr"
  RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
  PROWLARR_APPDATA="/media/Storage/AppData/prowlarr"
  SEERR_APPDATA="/media/Storage/AppData/seerr"
else
  TORBOX_MOUNT="/DATA/Media/torbox"
  LIBRARY_ROOT="/DATA/Media/library"
fi

TZ="${TZ:-Etc/UTC}"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as root over SSH (you should already be root on ZimaOS SSH)"

command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -e /dev/fuse ]] || die "/dev/fuse missing"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
fi

docker info >/dev/null 2>&1 || die "docker daemon not running"

# Match LinuxServer Plex UID if present
for name in $(docker ps --format '{{.Names}}' | grep -i plex || true); do
  PUID="$(docker exec "$name" id -u 2>/dev/null || echo "$PUID")"
  PGID="$(docker exec "$name" id -g 2>/dev/null || echo "$PGID")"
  echo "==> Found Plex container '$name' — using uid:gid ${PUID}:${PGID}"
  break
done

HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
SEERR_KEY="${BOXARR_SEERR_API_KEY:-$(openssl rand -hex 16 2>/dev/null || echo changeme1234567890)}"

echo "==> ZimaOS Boxarr installer"
echo "    install: ${INSTALL_DIR}"
echo "    mount:   ${TORBOX_MOUNT}"
echo "    library: ${LIBRARY_ROOT}"
echo "    puid:    ${PUID}:${PGID}"

[[ -n "${TORBOX_API_KEY:-}" ]] || read -r -p "TorBox API key: " TORBOX_API_KEY
[[ -n "${TORBOX_API_KEY:-}" ]] || die "TorBox API key required"

[[ -n "${TMDB_API_KEY:-}" ]] || read -r -p "TMDB API key: " TMDB_API_KEY
[[ -n "${TMDB_API_KEY:-}" ]] || die "TMDB API key required"

echo "==> Creating folders"
mkdir -p "${INSTALL_DIR}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}/cache" \
  "${PROWLARR_APPDATA}" "${SEERR_APPDATA}" \
  "${TORBOX_MOUNT}" "${LIBRARY_ROOT}/movies" "${LIBRARY_ROOT}/tv" "${LIBRARY_ROOT}/anime"

chown -R "${PUID}:${PGID}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}" \
  "${PROWLARR_APPDATA}" "${SEERR_APPDATA}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"
chmod -R u+rwX,g+rwX "${LIBRARY_ROOT}" "${TORBOX_MOUNT}"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  { grep -q '^#user_allow_other' /etc/fuse.conf && sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf; } || \
  echo "user_allow_other" >> /etc/fuse.conf

cat > "${RCLONE_APPDATA}/rclone.conf" <<EOF
[torbox]
type = webdav
url = https://webdav.torbox.app/
vendor = other
user = torbox
pass = ${TORBOX_API_KEY}
EOF
chmod 600 "${RCLONE_APPDATA}/rclone.conf"
chown "${PUID}:${PGID}" "${RCLONE_APPDATA}/rclone.conf"

SEERR_SVC=""
[[ "${INSTALL_SEERR}" == "1" ]] && SEERR_SVC="
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
      - 5055:5055
    networks: [boxarr-net]"

# Plain bind mounts — no propagation flags (ZimaOS GUI can't handle them; SSH compose can, but plain is safer)
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  boxarr-rclone:
    image: rclone/rclone:latest
    container_name: boxarr-rclone
    restart: unless-stopped
    cap_add: [SYS_ADMIN]
    devices: [/dev/fuse:/dev/fuse:rwm]
    security_opt: [apparmor:unconfined]
    volumes:
      - ${RCLONE_APPDATA}/rclone.conf:/config/rclone/rclone.conf:ro
      - ${RCLONE_APPDATA}/cache:/cache
      - /etc/fuse.conf:/etc/fuse.conf:ro
      - ${TORBOX_MOUNT}:/data
    command: >
      mount torbox: /data
      --allow-other --allow-non-empty --dir-cache-time 1h
      --vfs-cache-mode full --vfs-cache-max-size 50G
      --uid ${PUID} --gid ${PGID} --umask 002
      --cache-dir /cache --log-level INFO
    networks: [boxarr-net]

  boxarr:
    image: ghcr.io/radaiko/boxarr:latest
    container_name: boxarr
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    depends_on: [boxarr-rclone]
    environment:
      - BOXARR_DATABASE_PATH=/config/boxarr.db
      - BOXARR_LISTEN_ADDR=:8080
      - TZ=${TZ}
      - BOXARR_TORBOX_API_TOKEN=${TORBOX_API_KEY}
      - BOXARR_PROWLARR_URL=http://boxarr-prowlarr:9696
      - BOXARR_PROWLARR_API_KEY=__PROWLARR__
      - BOXARR_TMDB_API_KEY=${TMDB_API_KEY}
      - BOXARR_SEERR_API_KEYS=${SEERR_KEY}
      - BOXARR_WEBDAV_MOUNT_ROOT=/mnt/torbox
      - BOXARR_MOVIE_LIBRARY_ROOT=/mnt/library/movies
      - BOXARR_TV_LIBRARY_ROOT=/mnt/library/tv
      - BOXARR_ANIME_LIBRARY_ROOT=/mnt/library/anime
    ports: ["8181:8080"]
    volumes:
      - ${BOXARR_APPDATA}:/config
      - ${LIBRARY_ROOT}:/mnt/library
      - ${TORBOX_MOUNT}:/mnt/torbox
    networks: [boxarr-net]

  boxarr-prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: boxarr-prowlarr
    restart: unless-stopped
    environment:
      - PUID=${PUID}
      - PGID=${PGID}
      - TZ=${TZ}
    volumes:
      - ${PROWLARR_APPDATA}:/config
    ports: ["9696:9696"]
    networks: [boxarr-net]
${SEERR_SVC}

networks:
  boxarr-net:
    name: boxarr-net
EOF

echo "==> Starting Prowlarr"
DC pull
DC up -d boxarr-prowlarr

PKEY=""
for i in $(seq 1 30); do
  [[ -f "${PROWLARR_APPDATA}/config.xml" ]] && PKEY="$(grep -oP '(?<=<ApiKey>)[^<]+' "${PROWLARR_APPDATA}/config.xml" | head -1)" && [[ -n "$PKEY" ]] && break
  sleep 2
done
sed -i "s|__PROWLARR__|${PKEY}|" "${INSTALL_DIR}/docker-compose.yml"

echo "==> Starting all containers"
DC up -d
sleep 8

echo
echo "========== RESULT =========="
DC ps
echo
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep boxarr || true
echo
echo "Boxarr:   http://${HOST_IP}:8181"
echo "Prowlarr: http://${HOST_IP}:9696"
[[ "${INSTALL_SEERR}" == "1" ]] && echo "Seerr:    http://${HOST_IP}:5055"
echo
echo "Plex volumes to add (Settings → Volumes):"
echo "  ${LIBRARY_ROOT}  ->  /mnt/library"
echo "  ${TORBOX_MOUNT}  ->  /mnt/torbox"
echo "Plex libraries: /mnt/library/movies  /mnt/library/tv"
echo
if ! docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  echo "WARNING: boxarr-rclone failed — run: docker logs boxarr-rclone"
fi
