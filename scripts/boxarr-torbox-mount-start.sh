#!/usr/bin/env bash
# Wait for ZimaOS /DATA then start TorBox rclone mount (used by systemd).
set -euo pipefail

TORBOX_MOUNT="${TORBOX_MOUNT:-/DATA/Media/torbox}"
RCLONE_APPDATA="${RCLONE_APPDATA:-/DATA/AppData/boxarr-rclone}"
RCLONE_BIN="${RCLONE_BIN:-/usr/bin/rclone}"
PUID="${BOXARR_PUID:-1000}"
PGID="${BOXARR_PGID:-1000}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  TORBOX_MOUNT="/media/Storage/Media/torbox"
  RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
fi

[[ -x "${RCLONE_BIN}" ]] || RCLONE_BIN="$(command -v rclone)"

say() { echo "boxarr-torbox-mount: $*" >&2; }

say "waiting for ${RCLONE_APPDATA}/rclone.conf (up to 3 min)"
for _ in $(seq 1 90); do
  if [[ -f "${RCLONE_APPDATA}/rclone.conf" ]]; then
    break
  fi
  sleep 2
done
[[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || { say "rclone.conf missing"; exit 1; }

mkdir -p "${TORBOX_MOUNT}" "${RCLONE_APPDATA}/cache"
grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo "user_allow_other" >> /etc/fuse.conf

if command -v fusermount >/dev/null 2>&1; then
  fusermount -uz "${TORBOX_MOUNT}" 2>/dev/null || true
fi
pkill -f "rclone mount torbox: ${TORBOX_MOUNT}" 2>/dev/null || true
sleep 1

say "mounting torbox: -> ${TORBOX_MOUNT}"
exec "${RCLONE_BIN}" mount "torbox:" "${TORBOX_MOUNT}" \
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
  --log-level INFO
