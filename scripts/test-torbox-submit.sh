#!/usr/bin/env bash
# Test whether TorBox accepts torrent submissions at all (bypasses Prowlarr/Boxarr).
# Run on ZimaOS as root:
#   sudo TORBOX_API_KEY='your-key' bash test-torbox-submit.sh
# Or reads key from Boxarr DB if unset.

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

KEY="${TORBOX_API_KEY:-}"
if [[ -z "${KEY}" ]] && [[ -f "${DB}" ]]; then
  KEY="$(sqlite3 "${DB}" "SELECT value FROM settings WHERE key='torbox.token' LIMIT 1;" 2>/dev/null || true)"
fi
[[ -n "${KEY}" ]] || { echo "FAIL: set TORBOX_API_KEY or configure TorBox in Boxarr Settings"; exit 1; }

# Ubuntu 22.04 desktop amd64 — widely cached, known-good magnet
TEST_MAGNET='magnet:?xt=urn:btih:5b3f11bbba0a4d8c2e5e7c8e8e8e8e8e8e8e8e8e'
# Use a real well-known hash instead:
TEST_MAGNET='magnet:?xt=urn:btih:08F62A572C026BB2782297FED29226BFC47C90FF&dn=ubuntu-22.04.3-desktop-amd64.iso'

echo "=== 1. TorBox account (GET /user/me) ==="
ME="$(curl -sf -H "Authorization: Bearer ${KEY}" \
  "https://api.torbox.app/v1/api/user/me?settings=false" 2>&1)" || {
  echo "FAIL: TorBox API key rejected or network error"
  echo "${ME}"
  exit 1
}
echo "${ME}" | python3 -c "
import json,sys
d=json.load(sys.stdin).get('data',{})
print('  plan:', d.get('plan'), ' subscribed:', d.get('is_subscribed'))
print('  cooldown_until:', d.get('cooldown_until') or '(none)')
print('  total_downloaded:', d.get('total_downloaded'))
" 2>/dev/null || echo "${ME}"
echo

echo "=== 2. Submit known-good magnet (Ubuntu ISO) ==="
RESP="$(curl -s -w '\nHTTP_CODE:%{http_code}' -X POST \
  -H "Authorization: Bearer ${KEY}" \
  -F "magnet=${TEST_MAGNET}" \
  "https://api.torbox.app/v1/api/torrents/createtorrent")"
BODY="${RESP%HTTP_CODE:*}"
CODE="${RESP##*HTTP_CODE:}"
echo "  HTTP ${CODE}"
echo "${BODY}" | python3 -m json.tool 2>/dev/null || echo "${BODY}"
echo

if [[ "${CODE}" == "200" ]] || [[ "${CODE}" == "201" ]]; then
  echo "OK: TorBox accepts magnets — problem is indexer/release data or Boxarr, not your account."
  echo "     Delete the test torrent from torbox.app if you don't want it."
  exit 0
fi

echo "=== 3. Recent Boxarr failures (same error?) ==="
if [[ -f "${DB}" ]]; then
  sqlite3 -header -column "${DB}" \
    "SELECT substr(nzb_name,1,40) AS release, substr(fail_message,1,90) AS error FROM jobs WHERE state='failed' ORDER BY id DESC LIMIT 5;" 2>/dev/null || true
fi
echo

if echo "${BODY}" | grep -qi 'invalid magnet'; then
  echo "FAIL: TorBox rejected even a known-good magnet."
  echo "  → API key may be wrong type, or account restricted. Re-copy from torbox.app/settings"
elif echo "${BODY}" | grep -qi 'cooldown\|rate\|limit'; then
  echo "FAIL: TorBox rate limit / cooldown."
  echo "  If torbox.app shows no cooldown but Boxarr still paused, run: clear-boxarr-pause.sh"
elif [[ "${CODE}" == "401" ]] || [[ "${CODE}" == "403" ]]; then
  echo "FAIL: TorBox auth failed — paste API key again in Boxarr → Settings → Torbox"
else
  echo "FAIL: TorBox returned HTTP ${CODE}. Check response above."
fi
exit 1
