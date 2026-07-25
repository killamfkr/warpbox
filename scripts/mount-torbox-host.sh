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

TORBOX_MOUNT="/DATA/Media/torbox"
RCLONE_APPDATA="/DATA/AppData/boxarr-rclone"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  TORBOX_MOUNT="/media/Storage/Media/torbox"
  RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
fi

[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || die "missing ${RCLONE_APPDATA}/rclone.conf"

grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || \
  echo "user_allow_other" >> /etc/fuse.conf

mkdir -p "${TORBOX_MOUNT}" "${RCLONE_APPDATA}/cache"
chown -R "${PUID}:${PGID}" "${RCLONE_APPDATA}" "${TORBOX_MOUNT}"

# Stop compose rclone — host mount replaces it
docker rm -f boxarr-rclone 2>/dev/null || true
fusermount -uz "${TORBOX_MOUNT}" 2>/dev/null || umount -l "${TORBOX_MOUNT}" 2>/dev/null || true

install_rclone() {
  if command -v rclone >/dev/null 2>&1; then
    return 0
  fi
  say "Installing rclone on host"
  curl -fsSL https://rclone.org/install.sh | bash
  command -v rclone >/dev/null 2>&1 || die "rclone install failed"
}

mount_with_host_rclone() {
  say "Mounting TorBox on host with rclone (most reliable on ZimaOS)"
  install_rclone
  rclone mount "torbox:" "${TORBOX_MOUNT}" \
    --config "${RCLONE_APPDATA}/rclone.conf" \
    --allow-other \
    --allow-non-empty \
    --dir-cache-time 1h \
    --vfs-cache-mode full \
    --vfs-cache-max-size 50G \
    --cache-dir "${RCLONE_APPDATA}/cache" \
    --uid "${PUID}" \
    --gid "${PGID}" \
    --umask 002 \
    --log-file "${RCLONE_APPDATA}/mount.log" \
    --log-level INFO \
    --daemon
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
  for _ in $(seq 1 30); do
    if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]]; then
      ok "TorBox mounted at ${TORBOX_MOUNT}: $(ls "${TORBOX_MOUNT}" | head -3 | tr '\n' ' ')"
      return 0
    fi
    sleep 2
  done
  return 1
}

# Prefer host rclone — Docker FUSE propagation is unreliable on ZimaOS
if mount_with_host_rclone && wait_for_mount; then
  exit 0
fi

say "Host rclone mount empty — trying privileged docker"
docker rm -f boxarr-rclone 2>/dev/null || true
fusermount -uz "${TORBOX_MOUNT}" 2>/dev/null || true

if mount_with_docker && wait_for_mount; then
  exit 0
fi

echo "--- mount.log ---"
tail -20 "${RCLONE_APPDATA}/mount.log" 2>/dev/null || true
echo "--- docker logs ---"
docker logs boxarr-rclone --tail 20 2>/dev/null || true
echo "--- findmnt ---"
findmnt -T "${TORBOX_MOUNT}" 2>/dev/null || true
die "TorBox mount still empty at ${TORBOX_MOUNT}"
