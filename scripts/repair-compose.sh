#!/usr/bin/env bash
# Restore docker-compose.yml from backup, or regenerate if no backup exists.

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

RAW_BASE="${BOXARR_ZIMAOS_RAW:-https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

for bak in "${backups[@]}"; do
  say "trying ${bak}"
  if docker compose -f "${bak}" config >/dev/null 2>&1; then
    cp -a "${bak}" "${COMPOSE}"
    ok "restored ${COMPOSE} from ${bak}"
    exit 0
  fi
done

say "no valid backup — regenerating compose from Boxarr/Prowlarr data"
REGEN="${SCRIPT_DIR}/regenerate-compose.sh"
if [[ ! -f "${REGEN}" ]]; then
  curl -fsSL "${RAW_BASE}/regenerate-compose.sh" -o /tmp/regenerate-compose.sh
  REGEN="/tmp/regenerate-compose.sh"
fi
chmod +x "${REGEN}"
bash "${REGEN}"
