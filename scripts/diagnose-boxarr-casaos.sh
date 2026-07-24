#!/usr/bin/env bash
# Quick diagnostics for Boxarr stack on CasaOS / ZimaOS.
# Run as root:  curl -fsSL .../diagnose-boxarr-casaos.sh | sudo bash

set -u

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root — use: curl -fsSL .../diagnose-boxarr-casaos.sh | sudo bash" >&2
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

echo "=== recent logs ==="
for c in boxarr boxarr-rclone boxarr-prowlarr boxarr-seerr; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    echo "--- $c ---"
    docker logs "$c" --tail 8 2>&1
    echo
  fi
done
