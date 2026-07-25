#!/usr/bin/env bash
# Fix bad user: line in docker-compose.yml (e.g. user "user" instead of 1000:1000).
# sudo bash fix-compose-user.sh

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

COMPOSE="/DATA/AppData/boxarr-stack/docker-compose.yml"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && COMPOSE="/media/Storage/AppData/boxarr-stack/docker-compose.yml"
[[ -f "${COMPOSE}" ]] || { echo "FAIL: ${COMPOSE} not found"; exit 1; }

PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

for n in $(docker ps --format '{{.Names}}' 2>/dev/null | grep -i plex || true); do
  u="$(docker exec "$n" id -u 2>/dev/null || true)"
  g="$(docker exec "$n" id -g 2>/dev/null || true)"
  if [[ -n "$u" && "$u" =~ ^[0-9]+$ ]]; then
    PUID="$u"; PGID="$g"
    break
  fi
done

cp -a "${COMPOSE}" "${COMPOSE}.bak.user.$(date +%s)"
sed -i -E "s/^[[:space:]]+user:.*/    user: \"${PUID}:${PGID}\"/" "${COMPOSE}"

if docker compose -f "${COMPOSE}" config >/dev/null 2>&1; then
  echo "OK: fixed user to ${PUID}:${PGID}"
  echo "Run: cd $(dirname "${COMPOSE}") && docker compose up -d"
else
  echo "FAIL: compose still invalid — run regenerate-compose.sh"
  exit 1
fi
