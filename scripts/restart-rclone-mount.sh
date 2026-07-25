#!/usr/bin/env bash
# Restart the TorBox rclone mount (host systemd on ZimaOS).
#
# curl -fsSL .../restart-rclone-mount.sh | sudo bash

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
say "TorBox mount: ${TORBOX_MOUNT}"
say "rclone config: ${RCLONE_APPDATA}/rclone.conf"

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone not found after install"
fi
ok "rclone binary: ${RCLONE_BIN}"

say "Stopping old mount (docker + stale fuse)"
docker rm -f boxarr-rclone 2>/dev/null || true

say "Restarting host rclone mount"
if ! rclone_mount_restart_host; then
  echo "--- mount.log (last 25 lines) ---" >&2
  tail -25 "${RCLONE_APPDATA}/mount.log" 2>/dev/null || true
  echo "--- findmnt ---" >&2
  findmnt -T "${TORBOX_MOUNT}" 2>/dev/null || true
  die "TorBox mount still empty at ${TORBOX_MOUNT}"
fi

sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
ok "TorBox mounted: ${sample}"

if docker ps --format '{{.Names}}' | grep -qx boxarr; then
  say "Restarting boxarr so it picks up the mount"
  docker restart boxarr >/dev/null 2>&1 || true
fi

echo
echo "Commands for later:"
echo "  sudo systemctl status boxarr-torbox-mount"
echo "  sudo systemctl restart boxarr-torbox-mount"
echo "  tail -f ${RCLONE_APPDATA}/mount.log"
