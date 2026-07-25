#!/usr/bin/env bash
# Repair Boxarr stack on ZimaOS — run as root over SSH.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/fix-stack.sh -o /tmp/fix.sh && sed -i 's/\r$//' /tmp/fix.sh && chmod +x /tmp/fix.sh && sudo bash /tmp/fix.sh
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
[[ -f "${INSTALL_DIR}/docker-compose.yml" ]] || die "compose missing at ${INSTALL_DIR}/docker-compose.yml — run install.sh first"

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
for mp in /DATA /DATA/Media "${TORBOX_MOUNT}" "${LIBRARY_ROOT}"; do
  [[ -d "${mp}" ]] || continue
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
    die "TorBox WebDAV failed — set TORBOX_API_KEY and re-run: sudo TORBOX_API_KEY='...' bash fix-stack.sh"
  fi
  ok "TorBox WebDAV reachable"
fi

# --- fix compose: patch propagation in-place ---
COMPOSE="${INSTALL_DIR}/docker-compose.yml"
if grep -q 'command: >' "${COMPOSE}" 2>/dev/null; then
  die "compose has broken 'command: >' — re-run install.sh"
fi
if ! grep -q 'propagation: rshared' "${COMPOSE}" 2>/dev/null; then
  say "Patching compose for mount propagation (rshared/rslave)"
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -x "${SCRIPT_DIR}/patch-boxarr-compose.sh" ]]; then
    bash "${SCRIPT_DIR}/patch-boxarr-compose.sh" "${COMPOSE}" "${TORBOX_MOUNT}"
  else
    # inline patch when run via curl pipe
    cp -a "${COMPOSE}" "${COMPOSE}.bak.$(date +%s)"
    python3 - "${COMPOSE}" "${TORBOX_MOUNT}" <<'PY'
import re, sys
from pathlib import Path
path, torbox = Path(sys.argv[1]), sys.argv[2]
text = path.read_text()
def bind_block(src, tgt, prop):
    return (f"      - type: bind\n        source: {src}\n        target: {tgt}\n"
            f"        bind:\n          propagation: {prop}\n")
def sub_vol(text, host, ctr, prop):
    pat = rf'      - {re.escape(host)}:{re.escape(ctr)}\n'
    return re.sub(pat, bind_block(host, ctr, prop), text, count=1) if re.search(pat, text) else text
text = sub_vol(text, torbox, "/data", "rshared")
text = sub_vol(text, torbox, "/mnt/torbox", "rslave")
path.write_text(text)
print(f"patched {path}")
PY
  fi
  DC config >/dev/null || die "patched compose is invalid — restore from ${COMPOSE}.bak.*"
  ok "compose patched"
else
  ok "compose already has propagation"
fi

# --- restart in order ---
say "Stopping stack"
DC down 2>/dev/null || true
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  docker rm -f "${c}" 2>/dev/null || true
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-rclone-mount.sh
if [[ -f "${SCRIPT_DIR}/lib-rclone-mount.sh" ]]; then
  # shellcheck disable=SC1091
  . "${SCRIPT_DIR}/lib-rclone-mount.sh"
else
  curl -fsSL "https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/lib-rclone-mount.sh" \
    -o /tmp/lib-rclone-mount.sh
  # shellcheck disable=SC1091
  . /tmp/lib-rclone-mount.sh
fi
rclone_mount_paths

mounted=0
use_host=0
if rclone_mount_uses_host; then
  use_host=1
fi

if [[ "${use_host}" -eq 1 ]]; then
  say "Restarting host rclone mount (ZimaOS — not docker boxarr-rclone)"
  if rclone_mount_restart_host; then
    mounted=1
    ok "host TorBox mount: $(ls "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
  else
    warn "host rclone restart failed — trying mount-torbox-host.sh"
    if [[ -f "${SCRIPT_DIR}/mount-torbox-host.sh" ]]; then
      bash "${SCRIPT_DIR}/mount-torbox-host.sh" && mounted=1
    else
      curl -fsSL "https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/mount-torbox-host.sh" -o /tmp/mount-torbox.sh
      sed -i 's/\r$//' /tmp/mount-torbox.sh
      chmod +x /tmp/mount-torbox.sh
      bash /tmp/mount-torbox.sh && mounted=1
    fi
  fi
else
  say "Starting docker rclone (boxarr-rclone)"
  DC up -d boxarr-rclone
  say "Waiting for TorBox mount (up to 90s)..."
  for i in $(seq 1 45); do
    if docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
      if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]]; then
        mounted=1
        break
      fi
      if docker logs boxarr-rclone 2>&1 | grep -qi 'unknown command'; then
        die "rclone command broken in compose — re-run install.sh"
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
    warn "compose rclone mount empty — trying host mount fallback"
    if [[ -f "${SCRIPT_DIR}/mount-torbox-host.sh" ]]; then
      bash "${SCRIPT_DIR}/mount-torbox-host.sh" && mounted=1
    else
      curl -fsSL "https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/mount-torbox-host.sh" -o /tmp/mount-torbox.sh
      sed -i 's/\r$//' /tmp/mount-torbox.sh
      chmod +x /tmp/mount-torbox.sh
      bash /tmp/mount-torbox.sh && mounted=1
    fi
    use_host=1
  fi
fi

if [[ "${mounted}" -eq 0 ]]; then
  echo "--- rclone logs ---"
  docker logs boxarr-rclone --tail 30 2>/dev/null || true
  echo "--- host mount ---"
  ls -la "${TORBOX_MOUNT}" || true
  echo "--- fuse mounts ---"
  findmnt -t fuse.rclone 2>/dev/null || findmnt | grep -i fuse || true
  echo "--- inside container (if running) ---"
  docker run --rm --pid container:boxarr-rclone --privileged alpine ls -la /proc/1/root/data 2>/dev/null | head -10 || true
  die "TorBox mount still empty at ${TORBOX_MOUNT} — run: curl -fsSL .../restart-rclone-mount.sh | sudo bash"
fi

if [[ "${use_host}" -eq 1 ]]; then
  ok "TorBox mount active on host (systemd: boxarr-torbox-mount)"
else
  ok "boxarr-rclone running — $(ls "${TORBOX_MOUNT}" | head -3 | tr '\n' ' ')..."
fi

say "Starting rest of stack"
if [[ "${use_host}" -eq 1 ]]; then
  DC up -d boxarr boxarr-prowlarr boxarr-seerr 2>/dev/null || DC up -d boxarr boxarr-prowlarr
  ok "started stack (rclone runs on host, not in compose)"
else
  DC up -d
fi
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
for c in boxarr boxarr-prowlarr boxarr-seerr; do
  docker ps -a --format '{{.Names}}' | grep -qx "$c" || continue
  echo "[$c]"
  docker logs "$c" --tail 5 2>&1
  echo
done
if [[ "${use_host}" -eq 0 ]]; then
  docker ps -a --format '{{.Names}}' | grep -qx boxarr-rclone && {
    echo "[boxarr-rclone]"
    docker logs boxarr-rclone --tail 5 2>&1
    echo
  }
fi

if [[ "${use_host}" -eq 0 ]] && ! docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  die "boxarr-rclone still not running"
fi

if [[ "${use_host}" -eq 1 ]]; then
  if ! rclone_mount_wait_nonempty 1; then
    die "host TorBox mount is empty — run: curl -fsSL .../restart-rclone-mount.sh | sudo bash"
  fi
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
