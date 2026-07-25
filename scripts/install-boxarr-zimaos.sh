#!/usr/bin/env bash
# Boxarr + rclone + Prowlarr for ZimaOS (SSH required — web terminal often breaks).
#
# 1. ZimaOS → Settings → enable Developer Mode + SSH
# 2. SSH from your PC:  ssh root@<zima-ip>
# 3. Run this ONE line:
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-zimaos.sh -o /tmp/i.sh && sed -i 's/\r$//' /tmp/i.sh && chmod +x /tmp/i.sh && sudo bash /tmp/i.sh
#
# With keys (no prompts — recommended):
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-zimaos.sh -o /tmp/i.sh && sed -i 's/\r$//' /tmp/i.sh && chmod +x /tmp/i.sh && sudo TORBOX_API_KEY='key' TMDB_API_KEY='key' bash /tmp/i.sh

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

die() { echo "ERROR: $*" >&2; exit 1; }

on_err() {
  echo "ERROR: install failed at line ${1} (exit ${2})" >&2
  echo "Run diagnostics:" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/diagnose-boxarr-casaos.sh | sudo bash" >&2
  exit "${2}"
}
trap 'on_err ${LINENO} $?' ERR

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  command -v sudo >/dev/null 2>&1 || die "run as root: sudo bash /tmp/i.sh"
  exec sudo -E bash "${SCRIPT_PATH}" "$@"
fi

# ZimaOS often sets DOCKER_CONFIG=/DATA/.docker — breaks compose for non-root shells
if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ ! -r "${DOCKER_CONFIG}/config.json" ]] 2>/dev/null; then
  unset DOCKER_CONFIG
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker}"
mkdir -p "${DOCKER_CONFIG}/cli-plugins" 2>/dev/null || true

INSTALL_DIR="/DATA/AppData/boxarr-stack"
BOXARR_APPDATA="/DATA/AppData/boxarr"
RCLONE_APPDATA="/DATA/AppData/boxarr-rclone"
PROWLARR_APPDATA="/DATA/AppData/prowlarr"
SEERR_APPDATA="/DATA/AppData/seerr"
TORBOX_MOUNT="/DATA/Media/torbox"
LIBRARY_ROOT="/DATA/Media/library"
SEERR_UID="${SEERR_UID:-1000}"
SEERR_GID="${SEERR_GID:-1000}"
TZ="${TZ:-Etc/UTC}"
BOXARR_PORT="${BOXARR_PORT:-8181}"
PROWLARR_PORT="${PROWLARR_PORT:-9696}"
SEERR_PORT="${SEERR_PORT:-5055}"

# ZimaOS: prefer /DATA; some RAID setups use /media/Storage instead
if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  INSTALL_DIR="/media/Storage/AppData/boxarr-stack"
  BOXARR_APPDATA="/media/Storage/AppData/boxarr"
  RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
  PROWLARR_APPDATA="/media/Storage/AppData/prowlarr"
  SEERR_APPDATA="/media/Storage/AppData/seerr"
  TORBOX_MOUNT="/media/Storage/Media/torbox"
  LIBRARY_ROOT="/media/Storage/Media/library"
fi

command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -e /dev/fuse ]] || die "/dev/fuse missing — enable FUSE / Developer Mode"

setup_compose() {
  if docker compose version >/dev/null 2>&1; then
    DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
    return 0
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
    return 0
  fi
  local plugin
  for plugin in \
    /usr/lib/docker/cli-plugins/docker-compose \
    /usr/libexec/docker/cli-plugins/docker-compose \
    /usr/local/lib/docker/cli-plugins/docker-compose; do
    if [[ -x "${plugin}" ]]; then
      ln -sf "${plugin}" "${DOCKER_CONFIG}/cli-plugins/docker-compose" 2>/dev/null || true
      if docker compose version >/dev/null 2>&1; then
        DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
        return 0
      fi
    fi
  done
  return 1
}

setup_compose || die "docker compose not found — on ZimaOS run as root: docker compose version"

docker info >/dev/null 2>&1 || die "docker daemon not running — try: sudo systemctl start docker"

detect_puid() {
  local uid="" gid="" name
  while read -r name; do
    [[ -z "${name}" ]] && continue
    uid="$(docker exec "${name}" id -u 2>/dev/null || true)"
    gid="$(docker exec "${name}" id -g 2>/dev/null || true)"
    if [[ -n "${uid}" && "${uid}" != "0" ]]; then
      echo "==> Found Plex container '${name}' — using uid:gid ${uid}:${gid}" >&2
      echo "${uid} ${gid}"
      return
    fi
  done < <(docker ps --format '{{.Names}}' | grep -i plex || true)

  local user="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
  uid="$(id -u "${user}" 2>/dev/null || echo 1000)"
  gid="$(id -g "${user}" 2>/dev/null || echo 1000)"
  echo "${uid} ${gid}"
}

read -r PUID PGID < <(detect_puid)
PUID="${BOXARR_PUID:-${PUID:-1000}}"
PGID="${BOXARR_PGID:-${PGID:-1000}}"
[[ "${PUID}" =~ ^[0-9]+$ && "${PGID}" =~ ^[0-9]+$ ]] || die "invalid uid:gid ${PUID}:${PGID} — set BOXARR_PUID=1000 BOXARR_PGID=1000"

HOST_IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}')"
if [[ -z "${HOST_IP}" ]]; then
  HOST_IP="$( (ip -4 route get 1.1.1.1 2>/dev/null || true) | awk '{print $7; exit}' )"
fi
HOST_IP="${HOST_IP:-localhost}"

if [[ -n "${BOXARR_SEERR_API_KEY:-}" ]]; then
  SEERR_KEY="${BOXARR_SEERR_API_KEY}"
else
  SEERR_KEY="$(openssl rand -hex 16 2>/dev/null || true)"
  [[ -n "${SEERR_KEY}" ]] || SEERR_KEY="$( (head -c 16 /dev/urandom 2>/dev/null || true) | od -An -tx1 2>/dev/null | tr -d ' \n' || true)"
  SEERR_KEY="${SEERR_KEY:-seerr$(date +%s)}"
fi

echo "==> ZimaOS Boxarr installer"
echo "    install: ${INSTALL_DIR}"
echo "    mount:   ${TORBOX_MOUNT}"
echo "    library: ${LIBRARY_ROOT}"
echo "    puid:    ${PUID}:${PGID}"

if [[ -z "${TORBOX_API_KEY:-}" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "TorBox API key: " TORBOX_API_KEY
  else
    die "TORBOX_API_KEY required — pass inline: sudo TORBOX_API_KEY='...' TMDB_API_KEY='...' bash /tmp/i.sh"
  fi
fi
[[ -n "${TORBOX_API_KEY:-}" ]] || die "TorBox API key required"

if [[ -z "${TMDB_API_KEY:-}" ]]; then
  if [[ -t 0 ]]; then
    read -r -p "TMDB API key: " TMDB_API_KEY
  else
    die "TMDB_API_KEY required — pass inline: sudo TORBOX_API_KEY='...' TMDB_API_KEY='...' bash /tmp/i.sh"
  fi
fi
[[ -n "${TMDB_API_KEY:-}" ]] || die "TMDB API key required"

echo "==> Creating folders"
mkdir -p "${INSTALL_DIR}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}/cache" \
  "${PROWLARR_APPDATA}" "${SEERR_APPDATA}" \
  "${TORBOX_MOUNT}" "${LIBRARY_ROOT}/movies" "${LIBRARY_ROOT}/tv" "${LIBRARY_ROOT}/anime"

chown -R "${PUID}:${PGID}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}" \
  "${PROWLARR_APPDATA}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"
# Seerr image always runs as node (uid 1000) — not Plex PUID
chown -R "${SEERR_UID}:${SEERR_GID}" "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${LIBRARY_ROOT}" "${TORBOX_MOUNT}" "${RCLONE_APPDATA}" "${SEERR_APPDATA}"

# ZimaOS: FUSE mount inside rclone container must propagate to host so boxarr sees files
echo "==> Preparing host mount propagation"
for mp in "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"; do
  mount --bind "${mp}" "${mp}" 2>/dev/null || true
  mount --make-rshared "${mp}" 2>/dev/null || true
done

FUSE_CONF="/etc/fuse.conf"
if [[ -f "${FUSE_CONF}" ]]; then
  grep -q '^user_allow_other' "${FUSE_CONF}" || \
    sed -i 's/^#user_allow_other/user_allow_other/' "${FUSE_CONF}" 2>/dev/null || \
    echo "user_allow_other" >> "${FUSE_CONF}"
else
  echo "user_allow_other" > "${FUSE_CONF}"
fi

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
if [[ "${INSTALL_SEERR}" == "1" ]]; then
  SEERR_SVC="
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
      - ${SEERR_PORT}:5055
    networks: [boxarr-net]"
fi

# Plain bind mounts — no propagation flags (ZimaOS-safe)
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
    command:
      - mount
      - "torbox:"
      - /data
      - --allow-other
      - --allow-non-empty
      - --dir-cache-time
      - 1h
      - --vfs-cache-mode
      - full
      - --vfs-cache-max-size
      - 50G
      - --uid
      - "${PUID}"
      - --gid
      - "${PGID}"
      - --umask
      - "002"
      - --cache-dir
      - /cache
      - --log-level
      - INFO
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
      - BOXARR_PROWLARR_API_KEY=__PROWLARR_KEY__
      - BOXARR_TMDB_API_KEY=${TMDB_API_KEY}
      - BOXARR_SEERR_API_KEYS=${SEERR_KEY}
      - BOXARR_WEBDAV_MOUNT_ROOT=/mnt/torbox
      - BOXARR_MOVIE_LIBRARY_ROOT=/mnt/library/movies
      - BOXARR_TV_LIBRARY_ROOT=/mnt/library/tv
      - BOXARR_ANIME_LIBRARY_ROOT=/mnt/library/anime
    ports: ["${BOXARR_PORT}:8080"]
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
    ports: ["${PROWLARR_PORT}:9696"]
    networks: [boxarr-net]
${SEERR_SVC}

networks:
  boxarr-net:
    name: boxarr-net
EOF

chmod 755 "${INSTALL_DIR}"
chmod 644 "${INSTALL_DIR}/docker-compose.yml"

echo "==> Pulling images"
DC pull

echo "==> Removing any previous failed boxarr containers"
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  docker rm -f "${c}" 2>/dev/null || true
done

echo "==> Starting rclone (must mount before boxarr)"
DC up -d boxarr-rclone
echo "    waiting for TorBox mount..."
for _ in $(seq 1 45); do
  docker ps --format '{{.Names}}' | grep -qx boxarr-rclone || break
  [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]] && break
  docker logs boxarr-rclone 2>&1 | grep -qi 'unknown command' && die "rclone command broken — re-download install script"
  sleep 2
done

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
[[ -n "${PROWLARR_KEY}" ]] || die "Prowlarr API key not found — check: docker logs boxarr-prowlarr"

sed -i "s|__PROWLARR_KEY__|${PROWLARR_KEY}|" "${INSTALL_DIR}/docker-compose.yml"

echo "==> Starting all containers"
# Ensure Seerr can write /app/config (runs as node uid 1000)
chown -R "${SEERR_UID}:${SEERR_GID}" "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${SEERR_APPDATA}"
DC up -d
sleep 8

trap - ERR

echo
echo "========== RESULT =========="
DC ps
echo
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep boxarr || true
echo
echo "Boxarr:   http://${HOST_IP}:${BOXARR_PORT}"
echo "Prowlarr: http://${HOST_IP}:${PROWLARR_PORT}"
[[ "${INSTALL_SEERR}" == "1" ]] && echo "Seerr:    http://${HOST_IP}:${SEERR_PORT}"
echo
echo "Plex volumes to add (Settings → Volumes):"
echo "  ${LIBRARY_ROOT}  ->  /mnt/library"
echo "  ${TORBOX_MOUNT}  ->  /mnt/torbox"
echo "Plex libraries: /mnt/library/movies  /mnt/library/tv"
echo
if ! docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  echo "WARNING: boxarr-rclone not running"
  echo "  docker logs boxarr-rclone --tail 40"
fi
