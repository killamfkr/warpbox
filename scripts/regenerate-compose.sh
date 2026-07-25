#!/usr/bin/env bash
# Rebuild a valid docker-compose.yml from existing Boxarr stack data on disk.
# Use when compose was corrupted and no .bak backup exists.
#
# curl -fsSL .../regenerate-compose.sh -o /tmp/regenerate-compose.sh
# sudo bash /tmp/regenerate-compose.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && BASE="/media/Storage"

INSTALL_DIR="${BASE}/AppData/boxarr-stack"
COMPOSE="${INSTALL_DIR}/docker-compose.yml"
BOXARR_CFG="${BASE}/AppData/boxarr"
PROWLARR_CFG="${BASE}/AppData/prowlarr"
SEERR_CFG="${BASE}/AppData/seerr"
TORBOX_MOUNT="${BASE}/Media/torbox"
LIBRARY="${BASE}/Media/library"
PROWLARR_PROXY_URL="http://boxarr-prowlarr-proxy:9697"
TZ="${TZ:-Etc/UTC}"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

[[ -d "${BOXARR_CFG}" ]] || die "Boxarr not installed at ${BOXARR_CFG}"

yq() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

read_env_from_compose() {
  local key="$1" file="${2:-${COMPOSE}}"
  [[ -f "${file}" ]] || return 0
  grep -E "^[[:space:]]*${key}:" "${file}" 2>/dev/null | head -1 | sed -E "s/^[[:space:]]*${key}:[[:space:]]*//; s/^\"//; s/\"$//" || true
}

read_sqlite() {
  local key="$1" db="${BOXARR_CFG}/boxarr.db"
  [[ -f "${db}" ]] || return 0
  sqlite3 "${db}" "SELECT value FROM settings WHERE key='${key}' LIMIT 1;" 2>/dev/null || true
}

# PUID/PGID — must be numeric (broken compose may have parsed "user" as a username)
for n in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i plex || true); do
  u="$(docker exec "$n" id -u 2>/dev/null || true)"
  g="$(docker exec "$n" id -g 2>/dev/null || true)"
  if [[ -n "$u" && "$u" =~ ^[0-9]+$ ]]; then
    PUID="$u"; PGID="$g"
    break
  fi
done

if [[ -f "${COMPOSE}" ]]; then
  u="$(grep -E '^[[:space:]]+user:' "${COMPOSE}" 2>/dev/null | head -1 \
    | sed -nE 's/^[[:space:]]+user:[[:space:]]*"([0-9]+:[0-9]+)".*/\1/p')"
  if [[ -n "${u}" ]]; then
    PUID="${u%%:*}"; PGID="${u##*:}"
  fi
fi

[[ "${PUID}" =~ ^[0-9]+$ ]] || PUID=1000
[[ "${PGID}" =~ ^[0-9]+$ ]] || PGID=1000
say "using uid:gid ${PUID}:${PGID}"

PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_CFG}/config.xml" 2>/dev/null | head -1 || true)"
[[ -n "${PKEY}" ]] || PKEY="$(read_env_from_compose BOXARR_PROWLARR_API_KEY)"
[[ -n "${PKEY}" ]] || die "Prowlarr API key not found — is boxarr-prowlarr running?"

TORBOX_KEY="$(read_sqlite torbox.token)"
[[ -n "${TORBOX_KEY}" ]] || TORBOX_KEY="$(read_env_from_compose BOXARR_TORBOX_API_TOKEN)"
[[ -n "${TORBOX_KEY}" ]] || die "TorBox token missing — set in Boxarr UI or pass TORBOX_API_KEY=..."

TMDB_KEY="$(read_sqlite tmdb.token)"
[[ -n "${TMDB_KEY}" ]] || TMDB_KEY="$(read_env_from_compose BOXARR_TMDB_API_KEY)"
[[ -n "${TMDB_KEY}" ]] || die "TMDB key missing — set in Boxarr or pass TMDB_API_KEY=..."

SEERR_KEY="$(read_sqlite seerr.api_keys | cut -d, -f1)"
[[ -n "${SEERR_KEY}" ]] || SEERR_KEY="$(read_env_from_compose BOXARR_SEERR_API_KEYS | cut -d, -f1)"
[[ -n "${SEERR_KEY}" ]] || SEERR_KEY="$(openssl rand -hex 16 2>/dev/null || echo "seerr$(date +%s)")"

INSTALL_SEERR=0
if docker ps -a --format '{{.Names}}' | grep -qx boxarr-seerr 2>/dev/null \
  || [[ -d "${SEERR_CFG}" && -n "$(ls -A "${SEERR_CFG}" 2>/dev/null)" ]]; then
  INSTALL_SEERR=1
fi

TORBOX_Y="$(yq "${TORBOX_KEY}")"
TMDB_Y="$(yq "${TMDB_KEY}")"
SEERR_Y="$(yq "${SEERR_KEY}")"

if [[ -f "${COMPOSE}" ]]; then
  cp -a "${COMPOSE}" "${COMPOSE}.broken.$(date +%s)"
  say "saved broken compose to ${COMPOSE}.broken.*"
fi

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

say "Writing new ${COMPOSE}"
mkdir -p "${INSTALL_DIR}"
cat > "${COMPOSE}" <<EOF
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
      BOXARR_PROWLARR_API_KEY: "${PKEY}"
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
  docker compose -f "${COMPOSE}" config >/dev/null
else
  docker-compose -f "${COMPOSE}" config >/dev/null
fi

ok "compose regenerated and validates"
echo
echo "Next:"
echo "  cd ${INSTALL_DIR} && docker compose up -d"
echo "  curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-prowlarr-proxy.sh | sudo bash"
echo "  curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-flaresolverr.sh | sudo bash"
