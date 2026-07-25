#!/usr/bin/env bash
# Repair Boxarr stack on ZimaOS — run as root over SSH.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/fix-boxarr-zimaos.sh -o /tmp/fix.sh && sed -i 's/\r$//' /tmp/fix.sh && chmod +x /tmp/fix.sh && sudo bash /tmp/fix.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
warn(){ echo "WARN: $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ ! -r "${DOCKER_CONFIG}/config.json" ]] 2>/dev/null; then
  unset DOCKER_CONFIG
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker}"

INSTALL_DIR="/DATA/AppData/boxarr-stack"
BOXARR_APPDATA="/DATA/AppData/boxarr"
RCLONE_APPDATA="/DATA/AppData/boxarr-rclone"
PROWLARR_APPDATA="/DATA/AppData/prowlarr"
SEERR_APPDATA="/DATA/AppData/seerr"
TORBOX_MOUNT="/DATA/Media/torbox"
LIBRARY_ROOT="/DATA/Media/library"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  INSTALL_DIR="/media/Storage/AppData/boxarr-stack"
  RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
  PROWLARR_APPDATA="/media/Storage/AppData/prowlarr"
  SEERR_APPDATA="/media/Storage/AppData/seerr"
  TORBOX_MOUNT="/media/Storage/Media/torbox"
  LIBRARY_ROOT="/media/Storage/Media/library"
  BOXARR_APPDATA="/media/Storage/AppData/boxarr"
fi

echo "========== Boxarr ZimaOS repair =========="
echo "install: ${INSTALL_DIR}"
echo "mount:   ${TORBOX_MOUNT}"
echo "puid:    ${PUID}:${PGID}"
echo

command -v docker >/dev/null 2>&1 || die "docker not found"
docker info >/dev/null 2>&1 || die "docker not running — run as root"
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || die "compose missing at ${INSTALL_DIR}/docker-compose.yml — run install-boxarr-zimaos.sh first"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
fi

# --- permissions ---
echo "==> Fixing permissions"
mkdir -p "${TORBOX_MOUNT}" "${LIBRARY_ROOT}/movies" "${LIBRARY_ROOT}/tv" "${SEERR_APPDATA}"
chown -R "${PUID}:${PGID}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}" "${PROWLARR_APPDATA}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}" 2>/dev/null || true
chown -R 1000:1000 "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${LIBRARY_ROOT}" "${TORBOX_MOUNT}" "${RCLONE_APPDATA}" "${SEERR_APPDATA}"
ok "permissions set"

# --- host mount propagation (critical on ZimaOS) ---
echo "==> Enabling mount propagation on host"
for mp in "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"; do
  mkdir -p "${mp}"
  mount --bind "${mp}" "${mp}" 2>/dev/null || true
  mount --make-rshared "${mp}" 2>/dev/null || warn "could not make-rshared ${mp}"
done
ok "host mounts prepared"

# --- fix rclone command in compose if still using broken folded string ---
if grep -q 'command: >' "${INSTALL_DIR}/docker-compose.yml" 2>/dev/null; then
  warn "compose has broken 'command: >' — re-run install-boxarr-zimaos.sh to regenerate"
fi

# --- fuse ---
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  { grep -q '^#user_allow_other' /etc/fuse.conf && sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf; } || \
  echo "user_allow_other" >> /etc/fuse.conf
ok "fuse.conf OK"

# --- restart in order ---
echo "==> Stopping stack"
DC down 2>/dev/null || true
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  docker rm -f "${c}" 2>/dev/null || true
done

echo "==> Starting rclone first"
DC up -d boxarr-rclone
echo "    waiting for TorBox mount (up to 90s)..."
mounted=0
for i in $(seq 1 45); do
  if docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
    # mount succeeded if host dir is non-empty or has typical rclone content
    if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]] || \
       docker logs boxarr-rclone 2>&1 | grep -qiE 'mount.*succeeded|Serving'; then
      mounted=1
      break
    fi
    if docker logs boxarr-rclone 2>&1 | grep -qi 'unknown command'; then
      die "rclone command broken in compose — re-run install-boxarr-zimaos.sh"
    fi
  else
    warn "boxarr-rclone not running"
    docker logs boxarr-rclone --tail 15 2>&1 || true
    die "boxarr-rclone failed to start"
  fi
  sleep 2
done

if [[ "${mounted}" -eq 0 ]]; then
  warn "mount may still be empty — continuing anyway"
  docker logs boxarr-rclone --tail 20
fi
ok "boxarr-rclone running"

echo "==> Starting rest of stack"
DC up -d
sleep 10

# --- report ---
echo
echo "========== STATUS =========="
DC ps
echo
echo "--- mount check ---"
echo "host torbox: $(ls "${TORBOX_MOUNT}" 2>/dev/null | head -5 | tr '\n' ' ' || echo EMPTY)"
echo
echo "--- HTTP check ---"
for port_name in "8181:boxarr" "9696:prowlarr" "5055:seerr"; do
  port="${port_name%%:*}"
  name="${port_name##*:}"
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || echo 000)"
  echo "${name} :${port} -> HTTP ${code}"
done
echo
echo "--- logs (last 5 lines each) ---"
for c in boxarr-rclone boxarr boxarr-prowlarr boxarr-seerr; do
  docker ps -a --format '{{.Names}}' | grep -qx "$c" || continue
  echo "[$c]"
  docker logs "$c" --tail 5 2>&1
  echo
done

if ! docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  die "boxarr-rclone still not running"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8181/ 2>/dev/null || echo 000)"
if [[ "${code}" == "200" || "${code}" == "302" || "${code}" == "301" ]]; then
  ok "Boxarr responding on :8181"
  echo
  echo "Open: http://$(hostname -I 2>/dev/null | awk '{print $1}'):8181"
else
  warn "Boxarr not responding on :8181 (got ${code})"
  echo "Paste this output when asking for help."
  exit 1
fi
