#!/usr/bin/env bash
# Shared helpers for host TorBox rclone mounts on ZimaOS/CasaOS.
# Source from other scripts:  . "$(dirname "$0")/lib-rclone-mount.sh"

rclone_mount_paths() {
  TORBOX_MOUNT="${TORBOX_MOUNT:-/DATA/Media/torbox}"
  RCLONE_APPDATA="${RCLONE_APPDATA:-/DATA/AppData/boxarr-rclone}"
  if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
    TORBOX_MOUNT="/media/Storage/Media/torbox"
    RCLONE_APPDATA="/media/Storage/AppData/boxarr-rclone"
  fi
  PUID="${BOXARR_PUID:-1000}"
  PGID="${BOXARR_PGID:-1000}"
}

rclone_mount_bin() {
  if [[ -n "${RCLONE_BIN:-}" ]] && [[ -x "${RCLONE_BIN}" ]]; then
    return 0
  fi
  RCLONE_BIN="$(command -v rclone 2>/dev/null || true)"
  if [[ -z "${RCLONE_BIN}" ]] && [[ -x /usr/local/bin/rclone ]]; then
    RCLONE_BIN="/usr/local/bin/rclone"
  fi
  if [[ -z "${RCLONE_BIN}" ]] && [[ -x /usr/bin/rclone ]]; then
    RCLONE_BIN="/usr/bin/rclone"
  fi
  [[ -n "${RCLONE_BIN}" ]] || return 1
}

fusermount_bin() {
  if [[ -n "${FUSERMOUNT_BIN:-}" ]] && [[ -x "${FUSERMOUNT_BIN}" ]]; then
    return 0
  fi
  FUSERMOUNT_BIN="$(command -v fusermount 2>/dev/null || true)"
  if [[ -z "${FUSERMOUNT_BIN}" ]] && [[ -x /usr/bin/fusermount ]]; then
    FUSERMOUNT_BIN="/usr/bin/fusermount"
  fi
  if [[ -z "${FUSERMOUNT_BIN}" ]] && [[ -x /bin/fusermount ]]; then
    FUSERMOUNT_BIN="/bin/fusermount"
  fi
  [[ -n "${FUSERMOUNT_BIN}" ]] || return 1
}

rclone_mount_uses_host() {
  rclone_mount_paths
  if [[ -f "${RCLONE_APPDATA}/mount-mode" ]] && [[ "$(cat "${RCLONE_APPDATA}/mount-mode")" == "host" ]]; then
    return 0
  fi
  if systemctl list-unit-files boxarr-torbox-mount.service >/dev/null 2>&1 \
    && systemctl is-enabled boxarr-torbox-mount.service >/dev/null 2>&1; then
    return 0
  fi
  if findmnt -T "${TORBOX_MOUNT}" -o FSTYPE -n 2>/dev/null | grep -qi rclone; then
    return 0
  fi
  return 1
}

rclone_mount_unmount() {
  rclone_mount_paths
  fusermount_bin || true
  if [[ -n "${FUSERMOUNT_BIN:-}" ]]; then
    "${FUSERMOUNT_BIN}" -uz "${TORBOX_MOUNT}" 2>/dev/null || true
  fi
  umount -l "${TORBOX_MOUNT}" 2>/dev/null || true
  pkill -f "rclone mount torbox: ${TORBOX_MOUNT}" 2>/dev/null || true
  sleep 1
}

rclone_mount_start_daemon() {
  rclone_mount_paths
  rclone_mount_bin || return 1
  mkdir -p "${TORBOX_MOUNT}" "${RCLONE_APPDATA}/cache"
  "${RCLONE_BIN}" mount "torbox:" "${TORBOX_MOUNT}" \
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

rclone_mount_wait_nonempty() {
  rclone_mount_paths
  local tries="${1:-30}"
  for _ in $(seq 1 "${tries}"); do
    if [[ -n "$(ls -A "${TORBOX_MOUNT}" 2>/dev/null)" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

rclone_mount_write_systemd_unit() {
  rclone_mount_paths
  rclone_mount_bin || return 1
  fusermount_bin || true
  local unit="/etc/systemd/system/boxarr-torbox-mount.service"
  local fm="${FUSERMOUNT_BIN:-/usr/bin/fusermount}"
  cat > "${unit}" <<EOF
[Unit]
Description=TorBox rclone mount for Boxarr
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=forking
User=root
ExecStartPre=-${fm} -uz ${TORBOX_MOUNT}
ExecStartPre=-/usr/bin/docker rm -f boxarr-rclone
ExecStart=${RCLONE_BIN} mount torbox: ${TORBOX_MOUNT} \\
  --config ${RCLONE_APPDATA}/rclone.conf \\
  --allow-other --allow-non-empty \\
  --dir-cache-time 1h --vfs-cache-mode full --vfs-cache-max-size 50G \\
  --cache-dir ${RCLONE_APPDATA}/cache \\
  --uid ${PUID} --gid ${PGID} --umask 002 \\
  --log-file ${RCLONE_APPDATA}/mount.log --log-level INFO \\
  --daemon
ExecStop=-${fm} -uz ${TORBOX_MOUNT}
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable boxarr-torbox-mount.service >/dev/null 2>&1 || true
  echo host > "${RCLONE_APPDATA}/mount-mode"
}

rclone_mount_restart_host() {
  rclone_mount_paths
  [[ -f "${RCLONE_APPDATA}/rclone.conf" ]] || return 1

  docker rm -f boxarr-rclone 2>/dev/null || true
  rclone_mount_unmount

  rclone_mount_bin || return 1
  rclone_mount_write_systemd_unit

  if systemctl restart boxarr-torbox-mount.service; then
    rclone_mount_wait_nonempty 30 && return 0
  fi
  echo "--- systemctl status ---" >&2
  systemctl status boxarr-torbox-mount.service --no-pager -l 2>&1 | tail -20 >&2 || true

  rclone_mount_start_daemon || return 1
  rclone_mount_wait_nonempty 30
}
