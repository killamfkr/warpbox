#!/usr/bin/env bash
# Restore docker-compose.yml from the newest backup if the current file is invalid.
#
# sudo bash repair-compose.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

COMPOSE="/DATA/AppData/boxarr-stack/docker-compose.yml"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && COMPOSE="/media/Storage/AppData/boxarr-stack/docker-compose.yml"
[[ -f "${COMPOSE}" ]] || die "compose not found: ${COMPOSE}"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${COMPOSE}" "$@"; }
else
  DC() { docker-compose -f "${COMPOSE}" "$@"; }
fi

if DC config >/dev/null 2>&1; then
  ok "compose is valid — nothing to repair"
  exit 0
fi

say "compose is invalid — searching for backups"
mapfile -t backups < <(ls -t "${COMPOSE}".bak.* 2>/dev/null || true)
[[ ${#backups[@]} -gt 0 ]] || die "no backups at ${COMPOSE}.bak.* — paste compose for manual fix"

for bak in "${backups[@]}"; do
  say "trying ${bak}"
  if docker compose -f "${bak}" config >/dev/null 2>&1; then
    cp -a "${bak}" "${COMPOSE}"
    ok "restored ${COMPOSE} from ${bak}"
    DC config >/dev/null
    ok "compose validates"
    exit 0
  fi
done

die "no valid backup found — restore manually from ${COMPOSE}.bak.*"
