#!/usr/bin/env bash
# =============================================================================
# Boxarr stack for ZimaOS — one-shot installer (tested workflow)
# =============================================================================
#
# Installs everything in one run:
#   - Boxarr + Prowlarr + Seerr (docker compose)
#   - TorBox host rclone mount (ZimaOS-safe; no Docker FUSE propagation)
#   - Prowlarr torrent proxy (fixes Boxarr usenet-only search bug)
#   - systemd service so TorBox remounts on boot
#
# REQUIREMENTS: SSH as root, Developer Mode, TorBox + TMDB API keys
#
# ONE-LINER:
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-zimaos-once.sh -o /tmp/go.sh && sed -i 's/\r$//' /tmp/go.sh && chmod +x /tmp/go.sh && sudo TORBOX_API_KEY='YOUR_TORBOX_KEY' TMDB_API_KEY='YOUR_TMDB_KEY' bash /tmp/go.sh
#
# Skip Seerr:  INSTALL_SEERR=0 bash /tmp/go.sh
# =============================================================================

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
RAW_BASE="https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts"

say()  { echo "==> $*"; }
ok()   { echo "OK:  $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }
warn() { echo "WARN:  $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "${SCRIPT}" "$@"

if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ ! -r "${DOCKER_CONFIG}/config.json" ]] 2>/dev/null; then
  unset DOCKER_CONFIG
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker}"
mkdir -p "${DOCKER_CONFIG}/cli-plugins" 2>/dev/null || true

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
PROXY_DIR="${BASE}/AppData/boxarr-prowlarr-proxy"
TORBOX_MOUNT="${BASE}/Media/torbox"
LIBRARY="${BASE}/Media/library"
PROWLARR_PROXY_URL="http://boxarr-prowlarr-proxy:9697"

INSTALL_SEERR="${INSTALL_SEERR:-1}"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"
TZ="${TZ:-Etc/UTC}"

for n in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i plex || true); do
  u="$(docker exec "$n" id -u 2>/dev/null || true)"
  g="$(docker exec "$n" id -g 2>/dev/null || true)"
  if [[ -n "$u" && "$u" != "0" ]]; then
    PUID="$u"; PGID="$g"
    say "Matched Plex container '$n' → uid:gid ${PUID}:${PGID}"
    break
  fi
done

command -v docker >/dev/null 2>&1 || die "docker not found"
[[ -e /dev/fuse ]] || die "/dev/fuse missing — enable Developer Mode in ZimaOS"
docker info >/dev/null 2>&1 || die "cannot run docker — SSH as root"

[[ -n "${TORBOX_API_KEY:-}" ]] || { [[ -t 0 ]] && read -r -p "TorBox API key: " TORBOX_API_KEY; }
[[ -n "${TORBOX_API_KEY:-}" ]] || die "Set TORBOX_API_KEY=... on the command line"
[[ -n "${TMDB_API_KEY:-}" ]] || { [[ -t 0 ]] && read -r -p "TMDB API key (v4 read token): " TMDB_API_KEY; }
[[ -n "${TMDB_API_KEY:-}" ]] || die "Set TMDB_API_KEY=... on the command line"

SEERR_KEY="${BOXARR_SEERR_API_KEY:-$(openssl rand -hex 16 2>/dev/null || echo "seerr$(date +%s)")}"
yq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
TORBOX_Y="$(yq "$TORBOX_API_KEY")"
TMDB_Y="$(yq "$TMDB_API_KEY")"
SEERR_Y="$(yq "$SEERR_KEY")"

echo "========== Boxarr ZimaOS one-shot install =========="
say "base=${BASE}  torbox=${TORBOX_MOUNT}  uid:gid=${PUID}:${PGID}"
echo

# --- folders ---
say "Creating folders"
mkdir -p "${INSTALL_DIR}" "${BOXARR_CFG}" "${RCLONE_CFG}/cache" "${PROWLARR_CFG}" \
  "${SEERR_CFG}" "${PROXY_DIR}" "${TORBOX_MOUNT}" \
  "${LIBRARY}/movies" "${LIBRARY}/tv" "${LIBRARY}/anime"
chown -R "${PUID}:${PGID}" "${BOXARR_CFG}" "${RCLONE_CFG}" "${PROWLARR_CFG}" "${TORBOX_MOUNT}" "${LIBRARY}" "${PROXY_DIR}"
chown -R 1000:1000 "${SEERR_CFG}"
chmod -R u+rwX,g+rwX "${LIBRARY}" "${TORBOX_MOUNT}" "${RCLONE_CFG}" "${SEERR_CFG}" "${PROXY_DIR}"

for mp in /DATA /DATA/Media "${TORBOX_MOUNT}" "${LIBRARY}"; do
  [[ -d "${mp}" ]] || continue
  mount --make-rshared "${mp}" 2>/dev/null || true
done

if [[ -f /etc/fuse.conf ]]; then
  grep -q '^user_allow_other' /etc/fuse.conf || \
    sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf 2>/dev/null || \
    echo "user_allow_other" >> /etc/fuse.conf
else
  echo "user_allow_other" > /etc/fuse.conf
fi

# --- rclone config ---
say "Writing rclone config"
TORBOX_PASS="$(printf '%s' "${TORBOX_API_KEY}" | docker run --rm -i rclone/rclone obscure -)"
cat > "${RCLONE_CFG}/rclone.conf" <<EOF
[torbox]
type = webdav
url = https://webdav.torbox.app/
vendor = other
user = torbox
pass = ${TORBOX_PASS}
EOF
chmod 600 "${RCLONE_CFG}/rclone.conf"
chown "${PUID}:${PGID}" "${RCLONE_CFG}/rclone.conf"

docker run --rm -v "${RCLONE_CFG}/rclone.conf:/config/rclone/rclone.conf:ro" \
  rclone/rclone ls "torbox:" --max-depth 1 2>&1 | head -3 || die "TorBox WebDAV test failed"

# --- proxy script ---
say "Installing Prowlarr torrent proxy"
curl -fsSL "${RAW_BASE}/prowlarr-torrent-proxy.py" -o "${PROXY_DIR}/prowlarr-torrent-proxy.py"
chmod 644 "${PROXY_DIR}/prowlarr-torrent-proxy.py"

# --- compose (no docker rclone — host mount instead) ---
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

say "Writing docker-compose.yml"
cat > "${INSTALL_DIR}/docker-compose.yml" <<EOF
services:
  boxarr:
    image: ghcr.io/radaiko/boxarr:latest
    container_name: boxarr
    restart: unless-stopped
    user: "${PUID}:${PGID}"
    environment:
      BOXARR_DATABASE_PATH: /config/boxarr.db
      BOXARR_LISTEN_ADDR: ":8080"
      TZ: "${TZ}"
      BOXARR_TORBOX_API_TOKEN: "${TORBOX_Y}"
      BOXARR_PROWLARR_URL: "${PROWLARR_PROXY_URL}"
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
      - type: bind
        source: ${TORBOX_MOUNT}
        target: /mnt/torbox
        bind:
          propagation: rslave
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

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
fi
DC config >/dev/null || die "invalid docker-compose.yml"

# --- stop old stack ---
say "Stopping old containers"
DC down 2>/dev/null || true
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr boxarr-prowlarr-proxy; do
  docker rm -f "$c" 2>/dev/null || true
done
docker ps -a --format '{{.Names}}' | grep -E '^boxarr-prowlarr-proxy' | xargs -r docker rm -f 2>/dev/null || true

# --- host TorBox mount (systemd — starts on boot) ---
say "Mounting TorBox on host (rclone + systemd)"
LIB="${SCRIPT_DIR}/lib-rclone-mount.sh"
if [[ ! -f "${LIB}" ]]; then
  curl -fsSL "${RAW_BASE}/lib-rclone-mount.sh" -o /tmp/lib-rclone-mount.sh
  LIB="/tmp/lib-rclone-mount.sh"
fi
# shellcheck disable=SC1091
. "${LIB}"
export TORBOX_MOUNT="${TORBOX_MOUNT}" RCLONE_APPDATA="${RCLONE_CFG}" BOXARR_PUID="${PUID}" BOXARR_PGID="${PGID}"
rclone_mount_paths

docker rm -f boxarr-rclone 2>/dev/null || true
if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone install failed"
fi

if ! rclone_mount_enable_boot; then
  die "TorBox mount failed — see ${RCLONE_CFG}/mount.log and run enable-rclone-startup.sh"
fi
ok "TorBox mounted at ${TORBOX_MOUNT}"
ok "boxarr-torbox-mount.service enabled=$(systemctl is-enabled boxarr-torbox-mount.service 2>/dev/null || echo unknown)"

# --- start prowlarr, get key ---
say "Starting Prowlarr"
DC pull
DC up -d boxarr-prowlarr
PKEY=""
for _ in $(seq 1 60); do
  [[ -f "${PROWLARR_CFG}/config.xml" ]] && \
    PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_CFG}/config.xml" | head -1)" && \
    [[ -n "$PKEY" ]] && break
  sleep 2
done
[[ -n "$PKEY" ]] || die "Prowlarr API key not found"
sed -i "s|__PROWLARR__|${PKEY}|" "${INSTALL_DIR}/docker-compose.yml"

# --- prowlarr torrent proxy (exact container name for Docker DNS) ---
say "Starting Prowlarr torrent proxy"
docker run -d \
  --name boxarr-prowlarr-proxy \
  --restart unless-stopped \
  --network boxarr-net \
  -e PROWLARR_UPSTREAM=http://boxarr-prowlarr:9696 \
  -e PROWLARR_PROXY_PORT=9697 \
  -v "${PROXY_DIR}/prowlarr-torrent-proxy.py:/app/proxy.py:ro" \
  python:3-alpine python3 /app/proxy.py

sleep 2
docker run --rm --network boxarr-net curlimages/curl:latest \
  -sf -H "X-Api-Key: ${PKEY}" "${PROWLARR_PROXY_URL}/api/v1/indexer" >/dev/null \
  || die "Prowlarr proxy test failed — docker logs boxarr-prowlarr-proxy"
ok "Prowlarr proxy at ${PROWLARR_PROXY_URL}"

# --- start boxarr + seerr ---
say "Starting Boxarr + Seerr"
chown -R 1000:1000 "${SEERR_CFG}"
DC up -d
sleep 12

# --- report ---
IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}')"
IP="${IP:-<your-zima-ip>}"

echo
echo "============================================"
DC ps
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'boxarr-prowlarr-proxy|NAMES' || true
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
  [[ "$code" == "200" || "$code" == "302" ]] && echo "OK   Seerr   http://${IP}:5055/" || { echo "FAIL Seerr"; FAIL=1; }
fi

echo
echo "Plex volumes (Settings → Volumes):"
echo "  ${LIBRARY}  →  /mnt/library"
echo "  ${TORBOX_MOUNT}  →  /mnt/torbox"
echo
echo "Boxarr Prowlarr URL (pre-configured): ${PROWLARR_PROXY_URL}"
echo
echo "── Seerr API key (use for BOTH Sonarr + Radarr in Seerr) ──"
echo "  ${SEERR_KEY}"
echo
echo "  Get key later:  show-seerr-key.sh"
echo "  Or Boxarr UI:   Settings → Requests → Generate"
echo
echo "── Seerr → Settings → Services ──"
echo "  Option 1 (hostname / port / URL base):"
echo "    Sonarr:  boxarr : 8080  base /sonarr"
echo "    Radarr:  boxarr : 8080  base /radarr"
echo "  Option 2 (full URL):"
echo "    Sonarr:  http://boxarr:8080/sonarr"
echo "    Radarr:  http://boxarr:8080/radarr"
echo "  Docs: https://github.com/killamfkr/warpbox/tree/boxarr-zimaos/docs/seerr-setup.md"
echo
echo "Next steps:"
echo "  1. Prowlarr http://${IP}:9696 — add YTS + TPB (torrent indexers)"
echo "  2. Boxarr http://${IP}:8181 — Settings → TorBox: paste API key if empty"
echo "  3. Seerr http://${IP}:5055 — Sonarr+Radarr → Boxarr (see docs/seerr-setup.md on boxarr-zimaos branch)"
echo

[[ "${FAIL}" -eq 0 ]] || exit 1
ok "Install complete"
