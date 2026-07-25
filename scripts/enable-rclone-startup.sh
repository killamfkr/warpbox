#!/usr/bin/env bash
# Install/enable TorBox rclone mount to start automatically on boot (ZimaOS).
#
# curl -fsSL .../enable-rclone-startup.sh | sudo bash

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${SCRIPT_DIR}/lib-rclone-mount.sh"
if [[ ! -f "${LIB}" ]]; then
  curl -fsSL "https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts/lib-rclone-mount.sh" \
    -o /tmp/lib-rclone-mount.sh
  LIB="/tmp/lib-rclone-mount.sh"
fi
# shellcheck source=lib-rclone-mount.sh
. "${LIB}"

rclone_mount_paths
[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone not found after install"
fi

say "Installing systemd unit (starts on boot)"
rclone_mount_write_systemd_unit

say "Starting mount now"
systemctl start boxarr-torbox-mount.service

if rclone_mount_wait_nonempty 15; then
  sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
  ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
else
  echo "WARN: mount empty — check: tail -f ${RCLONE_APPDATA}/mount.log" >&2
fi

enabled="$(systemctl is-enabled boxarr-torbox-mount.service 2>/dev/null || echo unknown)"
active="$(systemctl is-active boxarr-torbox-mount.service 2>/dev/null || echo unknown)"
ok "boxarr-torbox-mount.service enabled=${enabled} active=${active}"
echo
echo "Useful commands:"
echo "  sudo systemctl status boxarr-torbox-mount"
echo "  sudo systemctl restart boxarr-torbox-mount"
echo "  tail -f ${RCLONE_APPDATA}/mount.log"
