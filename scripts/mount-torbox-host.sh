#!/usr/bin/env bash
# Mount TorBox on the ZimaOS host and enable boot persistence.
#
# curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/mount-torbox-host.sh -o /tmp/mount-torbox-host.sh
# sudo bash /tmp/mount-torbox-host.sh

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

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

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

mkdir -p "${TORBOX_MOUNT}" "${RCLONE_APPDATA}/cache"
chown -R "${PUID}:${PGID}" "${RCLONE_APPDATA}" "${TORBOX_MOUNT}"

docker rm -f boxarr-rclone 2>/dev/null || true

if ! rclone_mount_bin; then
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone install failed"
fi

say "Mounting TorBox and enabling systemd boot service"
rclone_mount_enable_boot || die "mount failed — see ${RCLONE_APPDATA}/mount.log"

sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
ok "boxarr-torbox-mount.service enabled=$(systemctl is-enabled boxarr-torbox-mount.service)"
