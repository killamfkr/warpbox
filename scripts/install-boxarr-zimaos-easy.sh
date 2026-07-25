#!/usr/bin/env bash
# =============================================================================
# Boxarr stack for ZimaOS — easy failsafe installer
# =============================================================================
#
# ZimaOS stores everything under /DATA (capital D).
# There is NO /data on the host — only paths inside Docker containers.
#
# REQUIREMENTS:
#   - SSH as root (not ZimaOS web terminal)
#   - Developer Mode + SSH enabled in ZimaOS settings
#   - TorBox API key + TMDB API key (v4 read token)
#
# ONE-LINER (replace your keys):
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-zimaos-easy.sh -o /tmp/go.sh && sed -i 's/\r$//' /tmp/go.sh && chmod +x /tmp/go.sh && sudo TORBOX_API_KEY='YOUR_TORBOX_KEY' TMDB_API_KEY='YOUR_TMDB_KEY' bash /tmp/go.sh
#
# Skip Seerr on first run (simpler):
#   ... INSTALL_SEERR=0 bash /tmp/go.sh
#
# =============================================================================

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

say()  { echo "==> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

# --- must be root ---
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  exec sudo -E bash "${SCRIPT}" "$@"
fi

# --- docker env (ZimaOS sets broken DOCKER_CONFIG) ---
if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ ! -r "${DOCKER_CONFIG}/config.json" ]] 2>/dev/null; then
  unset DOCKER_CONFIG
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker}"
mkdir -p "${DOCKER_CONFIG}/cli-plugins" 2>/dev/null || true

# =============================================================================
# PATHS — host side only uses /DATA or /media/Storage (never /data)
# =============================================================================
if [[ -d /DATA ]]; then
  BASE="/DATA"
elif [[ -d /media/Storage ]]; then
  BASE="/media/Storage"
else
  die "Neither /DATA nor /media/Storage found — is this ZimaOS?"
fi

INSTALL_DIR="${BASE}/AppData/boxarr-stack"
BOXARR_CFG="${BASE}/AppData/boxarr"
RCLONE_CFG="${BASE}/AppData/boxarr-rclone"
PROWLARR_CFG="${BASE}/AppData/prowlarr"
SEERR_CFG="${BASE}/AppData/seerr"
TORBOX_MOUNT="${BASE}/Media/torbox"      # host path → rclone mounts TorBox here
LIBRARY="${BASE}/Media/library"          # host path → Plex-friendly symlinks

INSTALL_SEERR="${INSTALL_SEERR:-1}"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"
TZ="${TZ:-Etc/UTC}"

# match Plex if running
for n in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i plex || true); do
  u="$(docker exec "$n" id -u 2>/dev/null || true)"
  g="$(docker exec "$n" id -g 2>/dev/null || true)"
  if [[ -n "$u" && "$u" != "0" ]]; then
    PUID="$u"; PGID="$g"
    say "Matched Plex container '$n' → uid:gid ${PUID}:${PGID}"
    break
  fi
done

# --- checks ---
command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -e /dev/fuse ]] || die "/dev/fuse missing — enable Developer Mode in ZimaOS"
docker info >/dev/null 2>&1 || die "cannot run docker — are you root?"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
elif command -v docker-compose >/dev/null 2>&1; then
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  die "docker compose not found"
fi

# --- API keys ---
[[ -n "${TORBOX_API_KEY:-}" ]] || { [[ -t 0 ]] && read -r -p "TorBox API key: " TORBOX_API_KEY; }
[[ -n "${TORBOX_API_KEY:-}" ]] || die "Set TORBOX_API_KEY=... on the command line"
[[ -n "${TMDB_API_KEY:-}" ]] || { [[ -t 0 ]] && read -r -p "TMDB API key (v4 read token): " TMDB_API_KEY; }
[[ -n "${TMDB_API_KEY:-}" ]] || die "Set TMDB_API_KEY=... on the command line"

SEERR_KEY="${BOXARR_SEERR_API_KEY:-$(openssl rand -hex 16 2>/dev/null || echo "seerr$(date +%s)")}"

# escape values for YAML double-quoted strings
yq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
TORBOX_Y="$(yq "$TORBOX_API_KEY")"
TMDB_Y="$(yq "$TMDB_API_KEY")"
SEERR_Y="$(yq "$SEERR_KEY")"

say "ZimaOS Boxarr easy install"
say "  host base:  ${BASE}"
say "  torbox dir: ${TORBOX_MOUNT}"
say "  library:    ${LIBRARY}"
say "  uid:gid:    ${PUID}:${PGID}"
echo

# --- folders ---
say "Creating folders under ${BASE}"
mkdir -p \
  "${INSTALL_DIR}" \
  "${BOXARR_CFG}" \
  "${RCLONE_CFG}/cache" \
  "${PROWLARR_CFG}" \
  "${SEERR_CFG}" \
  "${TORBOX_MOUNT}" \
  "${LIBRARY}/movies" \
  "${LIBRARY}/tv" \
  "${LIBRARY}/anime"

chown -R "${PUID}:${PGID}" "${BOXARR_CFG}" "${RCLONE_CFG}" "${PROWLARR_CFG}" "${TORBOX_MOUNT}" "${LIBRARY}"
chown -R 1000:1000 "${SEERR_CFG}"   # Seerr always runs as uid 1000
chmod -R u+rwX,g+rwX "${LIBRARY}" "${TORBOX_MOUNT}" "${RCLONE_CFG}" "${SEERR_CFG}"

# host mount propagation — required so boxarr container sees rclone FUSE mount
say "Enabling mount propagation"
for mp in "${TORBOX_MOUNT}" "${LIBRARY}"; do
  mount --bind "${mp}" "${mp}" 2>/dev/null || true
  mount --make-rshared "${mp}" 2>/dev/null || warn "rshared failed on ${mp} (may still work)"
done

# fuse
if [[ -f /etc/fuse.conf ]]; then
  grep -q '^user_allow_other' /etc/fuse.conf || \
    sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null || \
    echo "user_allow_other" >> /etc/fuse.conf
else
  echo "user_allow_other" > /etc/fuse.conf
fi

# rclone config
cat > "${RCLONE_CFG}/rclone.conf" <<EOF
[torbox]
type = webdav
url = https://webdav.torbox.app/
vendor = other
user = torbox
pass = ${TORBOX_API_KEY}
EOF
chmod 600 "${RCLONE_CFG}/rclone.conf"
chown "${PUID}:${PGID}" "${RCLONE_CFG}/rclone.conf"

# --- compose (rclone command MUST be array — not "command: >") ---
SEERR_BLOCK=""
if [[ "${INSTALL_SEERR}" == "1" ]]; then
  SEERR_BLOCK="
  boxarr-seerr:
    image: ghcr.io/seerr-team/seerr:latest
    container_name: boxarr-seerr
    init: true
    restart: unless-stopped
    environment:
      LOG_LEVEL: info
      TZ: \"${TZ}\"
      PORT: \"5055\"
    volumes:
      - ${SEERR_CFG}:/app/config
    ports:
      - \"5055:5055\"
    networks:
      - boxarr-net"
fi

say "Writing ${INSTALL_DIR}/docker-compose.yml"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  boxarr-rclone:
    image: rclone/rclone:latest
    container_name: boxarr-rclone
    restart: unless-stopped
    cap_add:
      - SYS_ADMIN
    devices:
      - "/dev/fuse:/dev/fuse:rwm"
    security_opt:
      - "apparmor:unconfined"
    volumes:
      - ${RCLONE_CFG}/rclone.conf:/config/rclone/rclone.conf:ro
      - ${RCLONE_CFG}/cache:/cache
      - /etc/fuse.conf:/etc/fuse.conf:ro
      - ${TORBOX_MOUNT}:/data
    command:
      - "mount"
      - "torbox:"
      - "/data"
      - "--allow-other"
      - "--allow-non-empty"
      - "--dir-cache-time"
      - "1h"
      - "--vfs-cache-mode"
      - "full"
      - "--vfs-cache-max-size"
      - "50G"
      - "--uid"
      - "${PUID}"
      - "--gid"
      - "${PGID}"
      - "--umask"
      - "002"
      - "--cache-dir"
      - "/cache"
      - "--log-level"
      - "INFO"
    networks:
      - boxarr-net

  boxarr:
    image: ghcr.io/radaiko/boxarr:latest
    container_name: boxarr
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    depends_on:
      - boxarr-rclone
    environment:
      BOXARR_DATABASE_PATH: /config/boxarr.db
      BOXARR_LISTEN_ADDR: ":8080"
      TZ: "${TZ}"
      BOXARR_TORBOX_API_TOKEN: "${TORBOX_Y}"
      BOXARR_PROWLARR_URL: "http://boxarr-prowlarr:9696"
      BOXARR_PROWLARR_API_KEY: "__PROWLARR__"
      BOXARR_TMDB_API_KEY: "${TMDB_Y}"
      BOXARR_SEERR_API_KEYS: "${SEERR_Y}"
      BOXARR_WEBDAV_MOUNT_ROOT: /mnt/torbox
      BOXARR_MOVIE_LIBRARY_ROOT: /mnt/library/movies
      BOXARR_TV_LIBRARY_ROOT: /mnt/library/tv
      BOXARR_ANIME_LIBRARY_ROOT: /mnt/library/anime
    ports:
      - "8181:8080"
    volumes:
      - ${BOXARR_CFG}:/config
      - ${LIBRARY}:/mnt/library
      - ${TORBOX_MOUNT}:/mnt/torbox
    networks:
      - boxarr-net

  boxarr-prowlarr:
    image: lscr.io/linuxserver/prowlarr:latest
    container_name: boxarr-prowlarr
    restart: unless-stopped
    environment:
      PUID: "${PUID}"
      PGID: "${PGID}"
      TZ: "${TZ}"
    volumes:
      - ${PROWLARR_CFG}:/config
    ports:
      - "9696:9696"
    networks:
      - boxarr-net
${SEERR_BLOCK}

networks:
  boxarr-net:
    name: boxarr-net
EOF

say "Validating compose file"
DC config >/dev/null || { DC config 2>&1; die "docker-compose.yml is invalid — see error above"; }
ok "compose file valid"

# --- clean start ---
say "Pulling images"
DC pull

say "Removing old containers"
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  docker rm -f "$c" 2>/dev/null || true
done

say "Starting rclone (TorBox mount) — must succeed before boxarr"
DC up -d boxarr-rclone
for i in $(seq 1 60); do
  docker ps --format '{{.Names}}' | grep -qx boxarr-rclone || {
    docker logs boxarr-rclone --tail 20
    die "boxarr-rclone crashed — see logs above"
  }
  docker logs boxarr-rclone 2>&1 | grep -qi 'unknown command' && die "rclone command broken in compose"
  [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]] && break
  [[ "$i" -eq 60 ]] && warn "TorBox mount still empty after 2min — continuing anyway"
  sleep 2
done
say "rclone running — ${TORBOX_MOUNT} mounted"

say "Starting Prowlarr"
DC up -d boxarr-prowlarr
PKEY=""
for _ in $(seq 1 60); do
  [[ -f "${PROWLARR_CFG}/config.xml" ]] && \
    PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_CFG}/config.xml" | head -1)" && \
    [[ -n "$PKEY" ]] && break
  sleep 2
done
[[ -n "$PKEY" ]] || die "Prowlarr API key not found — docker logs boxarr-prowlarr"
sed -i "s|__PROWLARR__|${PKEY}|" "${INSTALL_DIR}/docker-compose.yml"

say "Starting boxarr + seerr"
chown -R 1000:1000 "${SEERR_CFG}"
DC up -d
sleep 12

# --- verify ---
IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}')"
IP="${IP:-<your-zima-ip>}"

echo
echo "============================================"
DC ps
echo "============================================"
echo

FAIL=0
for check in "8181:Boxarr" "9696:Prowlarr"; do
  port="${check%%:*}"; name="${check##*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" || "$code" == "302" || "$code" == "301" ]]; then
    echo "OK   ${name}  http://${IP}:${port}/"
  else
    echo "FAIL ${name}  http://${IP}:${port}/  (HTTP ${code})"
    FAIL=1
  fi
done
if [[ "${INSTALL_SEERR}" == "1" ]]; then
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:5055/" 2>/dev/null || echo 000)"
  if [[ "$code" == "200" || "$code" == "302" ]]; then
    echo "OK   Seerr   http://${IP}:5055/"
  else
    echo "FAIL Seerr   http://${IP}:5055/  (HTTP ${code})"
    FAIL=1
  fi
fi

echo
echo "Host paths (for Plex app Settings → Volumes):"
echo "  ${LIBRARY}  →  /mnt/library"
echo "  ${TORBOX_MOUNT}  →  /mnt/torbox"
echo "Plex libraries: /mnt/library/movies  /mnt/library/tv"
echo
echo "Seerr API key for Boxarr: ${SEERR_KEY}"
echo

if [[ "$FAIL" -eq 1 ]]; then
  echo "Something failed. Run repair:"
  echo "  curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/fix-boxarr-zimaos.sh | sudo bash"
  echo
  echo "Or paste logs:"
  echo "  docker logs boxarr-rclone --tail 20"
  echo "  docker logs boxarr --tail 20"
  exit 1
fi

echo "All good. Open Boxarr and add Prowlarr indexers."
