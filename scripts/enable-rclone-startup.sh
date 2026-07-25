#!/usr/bin/env bash
# Install/enable TorBox rclone mount to start automatically on boot (ZimaOS).
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/enable-rclone-startup.sh -o /tmp/enable-rclone-startup.sh
# sudo bash /tmp/enable-rclone-startup.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

RAW_BASE="${BOXARR_ZIMAOS_RAW:-https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib-rclone-mount.sh"
if [[ ! -f "${LIB}" ]]; then
  curl -fsSL "${RAW_BASE}/lib-rclone-mount.sh" -o /tmp/lib-rclone-mount.sh
  LIB="/tmp/lib-rclone-mount.sh"
fi
# shellcheck source=/dev/null
. "${LIB}"

rclone_mount_paths
say "TorBox mount: ${TORBOX_MOUNT}"
say "rclone config: ${RCLONE_APPDATA}/rclone.conf"

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf — run install.sh first"

if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone not found after install"
fi
ok "rclone binary: ${RCLONE_BIN}"

say "Enabling boxarr-torbox-mount.service (starts on boot)"
MOUNT_OK=1
if ! rclone_mount_enable_boot; then
  warn "mount setup had issues — checking service anyway"
  MOUNT_OK=0
  systemctl status boxarr-torbox-mount.service --no-pager -l 2>&1 | tail -25 >&2 || true
fi

enabled="$(systemctl is-enabled boxarr-torbox-mount.service 2>/dev/null || echo unknown)"
active="$(systemctl is-active boxarr-torbox-mount.service 2>/dev/null || echo unknown)"

if [[ "${enabled}" != "enabled" ]]; then
  die "boxarr-torbox-mount.service is not enabled (got: ${enabled})"
fi

ok "boxarr-torbox-mount.service enabled=${enabled} active=${active}"

# Show whether boot hook is registered
if systemctl show boxarr-torbox-mount.service -p WantedBy --value 2>/dev/null | grep -q multi-user; then
  ok "registered for boot (multi-user.target)"
fi
[[ -f /etc/cron.d/boxarr-torbox-mount ]] && ok "cron @reboot fallback installed (90s delay)"

if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]]; then
  sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
  ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
elif [[ "${MOUNT_OK}" -eq 0 ]]; then
  warn "mount path empty — check: sudo tail -30 ${RCLONE_APPDATA}/mount.log"
  warn "retry: sudo systemctl restart boxarr-torbox-mount"
else
  ok "service enabled (mount may still be loading)"
fi

echo
echo "After reboot, verify:"
echo "  sudo systemctl is-enabled boxarr-torbox-mount"
echo "  sudo systemctl status boxarr-torbox-mount"
echo "  ls ${TORBOX_MOUNT}"
