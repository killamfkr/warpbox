#!/usr/bin/env bash
# Install/enable TorBox rclone mount to start automatically on boot (ZimaOS).
#
# Preferred (downloads script to disk first — works when systemd unit is missing):
#   curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts/enable-rclone-startup.sh -o /tmp/enable-rclone-startup.sh
#   sudo bash /tmp/enable-rclone-startup.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

command -v systemctl >/dev/null 2>&1 || die "systemctl not found — ZimaOS needs Developer Mode + SSH"

RAW_BASE="${WARPBOX_RAW_BASE:-https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts}"
LIB="/tmp/lib-rclone-mount.sh"
curl -fsSL "${RAW_BASE}/lib-rclone-mount.sh" -o "${LIB}"
# shellcheck source=/dev/null
. "${LIB}"

rclone_mount_paths
say "TorBox mount: ${TORBOX_MOUNT}"
say "rclone config: ${RCLONE_APPDATA}/rclone.conf"

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf — configure TorBox in Boxarr first"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone not found after install"
fi
ok "rclone binary: ${RCLONE_BIN}"

say "Writing /etc/systemd/system/boxarr-torbox-mount.service"
rclone_mount_write_systemd_unit
[[ -f /etc/systemd/system/boxarr-torbox-mount.service ]] || \
  die "systemd unit was not written — check disk permissions"

systemctl daemon-reload
systemctl enable boxarr-torbox-mount.service
ok "enabled boxarr-torbox-mount.service for boot"

say "Starting mount now"
systemctl start boxarr-torbox-mount.service || {
  echo "--- systemctl status ---" >&2
  systemctl status boxarr-torbox-mount.service --no-pager -l 2>&1 | tail -25 >&2 || true
  echo "--- mount.log ---" >&2
  tail -20 "${RCLONE_APPDATA}/mount.log" 2>/dev/null || true
  die "systemctl start failed"
}

if rclone_mount_wait_nonempty 20; then
  sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
  ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
else
  echo "WARN: mount empty — check: tail -f ${RCLONE_APPDATA}/mount.log" >&2
fi

enabled="$(systemctl is-enabled boxarr-torbox-mount.service 2>/dev/null || echo unknown)"
active="$(systemctl is-active boxarr-torbox-mount.service 2>/dev/null || echo unknown)"
ok "boxarr-torbox-mount.service enabled=${enabled} active=${active}"
echo
echo "After reboot, verify with:"
echo "  sudo systemctl status boxarr-torbox-mount"
echo "  ls ${TORBOX_MOUNT}"
