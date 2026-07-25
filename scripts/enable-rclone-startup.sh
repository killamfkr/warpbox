#!/usr/bin/env bash
# Install/enable TorBox rclone mount to start automatically on boot (ZimaOS).
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/boxarr-zimaos/main/scripts/enable-rclone-startup.sh -o /tmp/enable-rclone-startup.sh
# sudo bash /tmp/enable-rclone-startup.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

RAW_BASE="${WARPBOX_RAW_BASE:-https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts}"
LIB="/tmp/lib-rclone-mount.sh"
curl -fsSL "${RAW_BASE}/lib-rclone-mount.sh" -o "${LIB}"
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
rclone_mount_enable_boot || {
  systemctl status boxarr-torbox-mount.service --no-pager -l 2>&1 | tail -25 >&2 || true
  die "failed to enable/start boxarr-torbox-mount.service"
}

sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
ok "boxarr-torbox-mount.service enabled=$(systemctl is-enabled boxarr-torbox-mount.service) active=$(systemctl is-active boxarr-torbox-mount.service)"
echo
echo "After reboot:"
echo "  sudo systemctl status boxarr-torbox-mount"
echo "  ls ${TORBOX_MOUNT}"
