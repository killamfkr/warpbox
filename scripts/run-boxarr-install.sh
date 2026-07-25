#!/usr/bin/env bash
# Wrapper — downloads and runs install-boxarr-casaos.sh safely on CasaOS/ZimaOS.
# Paste this ENTIRE block as one command:
#
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-casaos.sh)"

SCRIPT_URL="${BOXARR_INSTALL_URL:-https://raw.githubusercontent.com/killamfkr/warpbox/cursor/casaos-install-script-1b99/scripts/install-boxarr-casaos.sh}"
TARGET="/tmp/install-boxarr.sh"

curl -fsSL "${SCRIPT_URL}" -o "${TARGET}" || exit 1
sed -i 's/\r$//' "${TARGET}" 2>/dev/null || true
chmod +x "${TARGET}"

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  exec bash "${TARGET}" "$@"
else
  exec sudo -E bash "${TARGET}" "$@"
fi
