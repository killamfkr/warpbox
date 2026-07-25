#!/usr/bin/env bash
# Quick diagnostics for Boxarr stack on CasaOS / ZimaOS.
# Run as root:  curl -fsSL .../diagnose.sh | sudo bash

set -u

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root — use: curl -fsSL .../diagnose.sh | sudo bash" >&2
  exit 1
fi

if [[ -n "${DOCKER_CONFIG:-}" ]] && [[ ! -r "${DOCKER_CONFIG}/config.json" ]] 2>/dev/null; then
  unset DOCKER_CONFIG
fi
export DOCKER_CONFIG="${DOCKER_CONFIG:-/root/.docker}"

echo "=== Boxarr diagnostics ==="
echo "user: $(id)"
echo "docker: $(command -v docker 2>/dev/null || echo MISSING)"
echo "DOCKER_CONFIG: ${DOCKER_CONFIG}"
if docker compose version >/dev/null 2>&1; then
  echo "compose: $(docker compose version 2>/dev/null | head -1)"
elif command -v docker-compose >/dev/null 2>&1; then
  echo "compose: docker-compose $(docker-compose version 2>/dev/null | head -1)"
else
  echo "compose: MISSING"
  for p in /usr/lib/docker/cli-plugins/docker-compose /usr/libexec/docker/cli-plugins/docker-compose; do
    [[ -x "$p" ]] && echo "  found plugin: $p"
  done
fi
echo "fuse: $(test -e /dev/fuse && echo OK || echo MISSING)"
echo "user_allow_other: $(grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null && echo OK || echo MISSING)"
echo

for d in /DATA/AppData/boxarr-stack /DATA/AppData/boxarr /DATA/AppData/boxarr-rclone /DATA/AppData/prowlarr /DATA/AppData/seerr /DATA/Media/torbox /DATA/Media/library; do
  if [[ -e "$d" ]]; then
    echo "OK  $d  $(stat -c '%U:%G %a' "$d" 2>/dev/null || ls -ld "$d")"
  else
    echo "MISS $d"
  fi
done
echo

if [[ -f /DATA/AppData/boxarr-stack/docker-compose.yml ]]; then
  echo "compose file: /DATA/AppData/boxarr-stack/docker-compose.yml"
else
  echo "compose file: MISSING (expected /DATA/AppData/boxarr-stack/docker-compose.yml)"
fi
echo

echo "=== docker ps ==="
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 | grep -E 'boxarr|NAMES' || docker ps 2>&1
echo

echo "=== TorBox rclone mount ==="
if [[ -f /DATA/AppData/boxarr-rclone/mount-mode ]] && [[ "$(cat /DATA/AppData/boxarr-rclone/mount-mode 2>/dev/null)" == "host" ]]; then
  echo "mode: host (systemd boxarr-torbox-mount)"
  systemctl is-enabled boxarr-torbox-mount.service 2>/dev/null | sed 's/^/boot: /' || echo "boot: not enabled — run scripts/enable-rclone-startup.sh"
  systemctl is-active boxarr-torbox-mount.service 2>/dev/null | sed 's/^/systemd: /' || echo "systemd: not installed"
else
  echo "mode: docker (boxarr-rclone container)"
fi
findmnt -T /DATA/Media/torbox 2>/dev/null || echo "findmnt unavailable"
echo "host torbox entries: $(ls -A /DATA/Media/torbox 2>/dev/null | wc -l)"
if docker ps --format '{{.Names}}' | grep -qx boxarr-rclone; then
  echo "probe via alpine (docker rclone — may be empty on ZimaOS):"
  docker run --rm -v /DATA/Media/torbox:/torbox:ro alpine ls /torbox 2>&1 | head -8 || true
fi
echo

echo "=== rclone WebDAV test ==="
if [[ -f /DATA/AppData/boxarr-rclone/rclone.conf ]]; then
  docker run --rm \
    -v /DATA/AppData/boxarr-rclone/rclone.conf:/config/rclone/rclone.conf:ro \
    rclone/rclone ls "torbox:" --max-depth 1 2>&1 | head -5 || echo "WebDAV test FAILED"
else
  echo "rclone.conf missing"
fi
echo

echo "=== compose propagation check ==="
if [[ -f /DATA/AppData/boxarr-stack/docker-compose.yml ]]; then
  grep -E 'propagation:|torbox:' /DATA/AppData/boxarr-stack/docker-compose.yml || echo "no propagation flags found"
fi
echo

echo "=== prowlarr torrent proxy ==="
if docker ps --format '{{.Names}}' | grep -qx boxarr-prowlarr-proxy; then
  echo "OK  boxarr-prowlarr-proxy"
else
  echo "MISS boxarr-prowlarr-proxy (Boxarr needs this for torrent-only Prowlarr)"
fi
echo

echo "=== failed torrent submits ==="
if [[ -f /DATA/AppData/boxarr/boxarr.db ]]; then
  sqlite3 /DATA/AppData/boxarr/boxarr.db \
    "SELECT COUNT(*) FROM jobs WHERE protocol='torrent' AND state='failed';" 2>/dev/null \
    | xargs -I{} echo "failed torrent jobs: {}"
  sqlite3 /DATA/AppData/boxarr/boxarr.db \
    "SELECT substr(fail_message,1,100) FROM jobs WHERE protocol='torrent' AND state='failed' ORDER BY id DESC LIMIT 1;" 2>/dev/null \
    | sed 's/^/last error: /' || true
  CACHED_CD="$(sqlite3 /DATA/AppData/boxarr/boxarr.db \
    "SELECT value FROM settings WHERE key='torbox.cooldown_until' LIMIT 1;" 2>/dev/null || true)"
  if [[ -n "${CACHED_CD}" ]]; then
    echo "WARN boxarr cached cooldown_until=${CACHED_CD}"
    echo "      If torbox.app shows no cooldown: clear-boxarr-cooldown.sh"
  fi
fi
echo

echo "=== recent logs ==="
for c in boxarr boxarr-prowlarr-proxy boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    echo "--- $c ---"
    docker logs "$c" --tail 8 2>&1
    echo
  fi
done
