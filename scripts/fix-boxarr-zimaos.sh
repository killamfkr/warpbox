#!/usr/bin/env bash
# Repair Boxarr stack on ZimaOS — run as root over SSH.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/fix-boxarr-zimaos.sh -o /tmp/fix.sh && sed -i 's/\r$//' /tmp/fix.sh && chmod +x /tmp/fix.sh && sudo bash /tmp/fix.sh
#
# Re-run with API key if rclone auth fails:
#   sudo TORBOX_API_KEY='your-key' bash /tmp/fix.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
warn(){ echo "WARN: $*" >&2; }
say() { echo "==> $*"; }

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
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || die "compose missing at ${INSTALL_DIR}/docker-compose.yml — run install-boxarr-zimaos-easy.sh first"

if docker compose version >/dev/null 2>&1; then
  DC() { docker compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
else
  DC() { docker-compose -f "${INSTALL_DIR}/docker-compose.yml" "$@"; }
fi

# --- permissions ---
say "Fixing permissions"
mkdir -p "${TORBOX_MOUNT}" "${LIBRARY_ROOT}/movies" "${LIBRARY_ROOT}/tv" "${SEERR_APPDATA}"
chown -R "${PUID}:${PGID}" "${BOXARR_APPDATA}" "${RCLONE_APPDATA}" "${PROWLARR_APPDATA}" "${TORBOX_MOUNT}" "${LIBRARY_ROOT}" 2>/dev/null || true
chown -R 1000:1000 "${SEERR_APPDATA}"
chmod -R u+rwX,g+rwX "${LIBRARY_ROOT}" "${TORBOX_MOUNT}" "${RCLONE_APPDATA}" "${SEERR_APPDATA}"
ok "permissions set"

# --- host mount propagation (critical on ZimaOS) ---
say "Enabling mount propagation on host"
for mp in "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"; do
  mkdir -p "${mp}"
  mount --bind "${mp}" "${mp}" 2>/dev/null || true
  mount --make-rshared "${mp}" 2>/dev/null || warn "could not make-rshared ${mp}"
done
ok "host mounts prepared"

# --- fuse ---
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  { grep -q '^#user_allow_other' /etc/fuse.conf && sed -i 's/^#user_allow_other/user_allow_other/' /etc/fuse.conf; } || \
  echo "user_allow_other" >> /etc/fuse.conf
ok "fuse.conf OK"

# --- rclone config: ensure obscured password ---
if [[ -f "${RCLONE_APPDATA}/rclone.conf" ]]; then
  current_pass="$(sed -n 's/^pass = //p' "${RCLONE_APPDATA}/rclone.conf" | head -1)"
  if [[ -n "${TORBOX_API_KEY:-}" ]]; then
  say "Rewriting rclone.conf with obscured TorBox API key"
  TORBOX_PASS="$(printf '%s' "${TORBOX_API_KEY}" | docker run --rm -i rclone/rclone obscure -)"
  cat > "${RCLONE_APPDATA}/rclone.conf" <<EOF
[torbox]
type = webdav
url = https://webdav.torbox.app/
vendor = other
user = torbox
pass = ${TORBOX_PASS}
EOF
  chmod 600 "${RCLONE_APPDATA}/rclone.conf"
  chown "${PUID}:${PGID}" "${RCLONE_APPDATA}/rclone.conf"
  elif [[ -n "${current_pass}" ]] && [[ "${current_pass}" != *"_"* ]] && [[ "${#current_pass}" -lt 20 ]]; then
    warn "rclone.conf pass looks like plain text — re-run with TORBOX_API_KEY=... to fix auth"
  fi
fi

# --- test WebDAV before mount ---
if [[ -f "${RCLONE_APPDATA}/rclone.conf" ]]; then
  say "Testing TorBox WebDAV (rclone ls)"
  if ! docker run --rm \
    -v "${RCLONE_APPDATA}/rclone.conf:/config/rclone/rclone.conf:ro" \
    rclone/rclone ls "torbox:" --max-depth 1 2>&1 | head -3; then
    die "TorBox WebDAV failed — set TORBOX_API_KEY and re-run: sudo TORBOX_API_KEY='...' bash fix-boxarr-zimaos.sh"
  fi
  ok "TorBox WebDAV reachable"
fi

# --- fix compose: broken command or missing bind propagation ---
COMPOSE="${INSTALL_DIR}/docker-compose.yml"
needs_regen=0
if grep -q 'command: >' "${COMPOSE}" 2>/dev/null; then
  warn "compose has broken 'command: >' — re-run install-boxarr-zimaos-easy.sh to regenerate"
  needs_regen=1
fi
if ! grep -q 'propagation: rshared' "${COMPOSE}" 2>/dev/null; then
  warn "compose missing rshared propagation on rclone mount — re-run install-boxarr-zimaos-easy.sh"
  needs_regen=1
fi
[[ "${needs_regen}" -eq 1 ]] && warn "Continuing with current compose; mount may stay empty without propagation fix"

# --- restart in order ---
say "Stopping stack"
DC down 2>/dev/null || true
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  docker rm -f "${c}" 2>/dev/null || true
done

say "Starting rclone first"
DC up -d boxarr-rclone
say "Waiting for TorBox mount (up to 90s)..."
mounted=0
for i in $(seq 1 45); do
  if docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
    if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]]; then
      mounted=1
      break
    fi
    if docker logs boxarr-rclone 2>&1 | grep -qi 'unknown command'; then
      die "rclone command broken in compose — re-run install-boxarr-zimaos-easy.sh"
    fi
    if docker logs boxarr-rclone 2>&1 | grep -qiE '401|not authenticated|password was incorrect'; then
      docker logs boxarr-rclone --tail 15
      die "TorBox auth failed — re-run with TORBOX_API_KEY=..."
    fi
  else
    warn "boxarr-rclone not running"
    docker logs boxarr-rclone --tail 15 2>&1 || true
    die "boxarr-rclone failed to start"
  fi
  sleep 2
done

if [[ "${mounted}" -eq 0 ]]; then
  echo "--- rclone logs ---"
  docker logs boxarr-rclone --tail 30
  echo "--- host mount ---"
  ls -la "${TORBOX_MOUNT}" || true
  echo "--- propagation ---"
  findmnt -T "${TORBOX_MOUNT}" 2>/dev/null || true
  die "TorBox mount still empty at ${TORBOX_MOUNT}"
fi
ok "boxarr-rclone running — $(ls "${TORBOX_MOUNT}" | head -3 | tr '\n' ' ')..."

say "Starting rest of stack"
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
