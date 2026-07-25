#!/usr/bin/env bash
# Mount TorBox on the ZimaOS host (bypasses Docker FUSE propagation issues).
# Run as root after rclone.conf exists with obscured pass.
#
# curl -fsSL .../mount-torbox-host.sh | sudo bash

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-rclone-mount.sh
. "${SCRIPT_DIR}/lib-rclone-mount.sh"
rclone_mount_paths

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

mkdir -p "${TORBOX_MOUNT}" "${RCLONE_APPDATA}/cache"
chown -R "${PUID}:${PGID}" "${RCLONE_APPDATA}" "${TORBOX_MOUNT}"

# Stop compose rclone — host mount replaces it
docker rm -f boxarr-rclone 2>/dev/null || true
rclone_mount_unmount

install_rclone() {
  if rclone_mount_bin; then
    return 0
  fi
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  rclone_mount_bin || die "rclone install failed"
}

mount_with_host_rclone() {
  say "Mounting TorBox on host with rclone (most reliable on ZimaOS)"
  install_rclone
  rclone_mount_start_daemon
}

mount_with_docker() {
  say "Mounting TorBox with privileged docker (fallback)"
  docker run -d \
    --name boxarr-rclone \
    --restart unless-stopped \
    --privileged \
    --cap-add SYS_ADMIN \
    --device /dev/fuse:/dev/fuse:rwm \
    --security-opt apparmor:unconfined \
    -v "${RCLONE_APPDATA}/rclone.conf:/config/rclone/rclone.conf:ro" \
    -v "${RCLONE_APPDATA}/cache:/cache" \
    -v /etc/fuse.conf:/etc/fuse.conf:ro \
    --mount "type=bind,source=${TORBOX_MOUNT},target=/data,bind-propagation=rshared" \
    rclone/rclone \
    mount torbox: /data \
    --allow-other \
    --allow-non-empty \
    --dir-cache-time 1h \
    --vfs-cache-mode full \
    --vfs-cache-max-size 50G \
    --uid "${PUID}" \
    --gid "${PGID}" \
    --umask 002 \
    --cache-dir /cache \
    --log-level INFO
}

wait_for_mount() {
  rclone_mount_wait_nonempty 30
}

install_systemd_service() {
  say "Installing systemd service for boot persistence"
  rclone_mount_write_systemd_unit
  ok "enabled boxarr-torbox-mount.service (starts on boot)"
}

# Prefer host rclone — Docker FUSE propagation is unreliable on ZimaOS
if mount_with_host_rclone && wait_for_mount; then
  install_systemd_service
  sample="$(ls -A "${TORBOX_MOUNT}" 2>/dev/null | head -3 | tr '\n' ' ')"
  ok "TorBox mounted at ${TORBOX_MOUNT}: ${sample}"
  echo
  echo "Next: cd /DATA/AppData/boxarr-stack && docker compose up -d boxarr boxarr-prowlarr boxarr-seerr"
  exit 0
fi

say "Host rclone mount empty — trying privileged docker"
docker rm -f boxarr-rclone 2>/dev/null || true
fusermount -uz "${TORBOX_MOUNT}" 2>/dev/null || true

if mount_with_docker && wait_for_mount; then
  echo docker > "${RCLONE_APPDATA}/mount-mode"
  exit 0
fi

echo "--- mount.log ---"
tail -20 "${RCLONE_APPDATA}/mount.log" 2>/dev/null || true
echo "--- docker logs ---"
docker logs boxarr-rclone --tail 20 2>/dev/null || true
echo "--- findmnt ---"
findmnt -T "${TORBOX_MOUNT}" 2>/dev/null || true
die "TorBox mount still empty at ${TORBOX_MOUNT}"
