#!/usr/bin/env bash
# Stop Boxarr from retrying grabs while TorBox account cooldown is active.
#
# Failed/invalid magnet submissions can trigger a real ~24h TorBox cooldown.
# Boxarr will keep pending jobs and auto-search loops that hammer TorBox again
# the moment cooldown ends unless you freeze it first.
#
# Run on ZimaOS:
#   sudo bash freeze-boxarr-cooldown.sh          # diagnose + freeze if cooldown active
#   sudo bash freeze-boxarr-cooldown.sh --force  # freeze even if API looks clear

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

[[ -f "${DB}" ]] || { echo "FAIL: boxarr.db not found at ${DB}"; exit 1; }

read_setting() {
  sqlite3 "${DB}" "SELECT value FROM settings WHERE key='$1' LIMIT 1;" 2>/dev/null || true
}

KEY="$(read_setting torbox.token)"
CACHED_CD="$(read_setting torbox.cooldown_until)"

echo "=== Boxarr cooldown freeze ==="
echo "db: ${DB}"
echo

TB_COOLDOWN=""
TB_STATE="none"
if [[ -n "${KEY}" ]]; then
  ME="$(curl -sf -H "Authorization: Bearer ${KEY}" \
    "https://api.torbox.app/v1/api/user/me?settings=false" 2>&1)" || ME=""
  if [[ -n "${ME}" ]]; then
    eval "$(echo "${ME}" | python3 -c "
import json, sys
from datetime import datetime, timezone
d = json.load(sys.stdin).get('data', {})
cd = (d.get('cooldown_until') or '').strip()
print('cooldown_raw=%r' % cd)
if not cd:
    print('state=none')
else:
    try:
        until = datetime.fromisoformat(cd.replace('Z', '+00:00'))
        if until.tzinfo is None:
            until = until.replace(tzinfo=timezone.utc)
        print('state=active' if until > datetime.now(timezone.utc) else 'expired')
    except Exception:
        print('state=unparseable')
" 2>/dev/null || true)"
    TB_COOLDOWN="${cooldown_raw:-}"
    TB_STATE="${state:-unknown}"
    echo "TorBox cooldown_until: ${TB_COOLDOWN:-"(none)"}  (${TB_STATE})"
  fi
else
  echo "WARN: no torbox.token — cannot query TorBox API"
fi
echo "Boxarr cached cooldown: ${CACHED_CD:-"(none)"}"
echo

PENDING="$(sqlite3 "${DB}" "SELECT COUNT(*) FROM jobs WHERE state='pending';" 2>/dev/null || echo 0)"
SUBMITTING="$(sqlite3 "${DB}" "SELECT COUNT(*) FROM jobs WHERE state='submitting';" 2>/dev/null || echo 0)"
FAILED="$(sqlite3 "${DB}" "SELECT COUNT(*) FROM jobs WHERE state='failed';" 2>/dev/null || echo 0)"
echo "jobs pending:    ${PENDING}"
echo "jobs submitting: ${SUBMITTING}"
echo "jobs failed:     ${FAILED}"
echo

echo "=== Recent TorBox limit events (Boxarr log) ==="
sqlite3 -header -column "${DB}" \
  "SELECT kind, substr(detail,1,80) AS detail, created_at
   FROM limit_event ORDER BY id DESC LIMIT 8;" 2>/dev/null \
  || echo "(no limit_event table or empty)"
echo

echo "=== Recent failed grabs ==="
sqlite3 -header -column "${DB}" \
  "SELECT id, substr(nzb_name,1,40) AS release, substr(fail_message,1,90) AS error
   FROM jobs WHERE state='failed' ORDER BY id DESC LIMIT 6;" 2>/dev/null || true
echo

if [[ "${TB_STATE}" != "active" ]] && [[ "${FORCE}" -eq 0 ]]; then
  echo "TorBox does not show an active account cooldown."
  echo "If Boxarr UI still shows paused, run: clear-boxarr-pause.sh"
  echo "To freeze pending retries anyway: sudo bash $0 --force"
  exit 0
fi

if [[ "${TB_STATE}" == "active" ]]; then
  echo "ACTIVE TorBox cooldown — Boxarr cannot submit until it clears."
  echo "DMM may still work for cached torrents; new Boxarr grabs are blocked."
  echo
fi

echo "=== Freezing Boxarr (stop retry storm) ==="

docker stop boxarr 2>/dev/null || true

sqlite3 "${DB}" <<'SQL'
-- Pause auto-search / auto-grab loops
INSERT INTO settings(key, value) VALUES('automation.enabled', 'false')
  ON CONFLICT(key) DO UPDATE SET value='false';

-- Retire jobs that would submit the instant cooldown ends
UPDATE jobs
SET state='manually_resolved',
    fail_message='frozen during TorBox cooldown — search again after cooldown clears'
WHERE state IN ('pending', 'submitting');

-- Unlink wanted items stuck in queued/searching from dead jobs
UPDATE movie
SET status='wanted', job_id=NULL
WHERE has_file=0 AND status IN ('queued', 'searching', 'downloading', 'failed');

UPDATE episode
SET status='wanted', job_id=NULL
WHERE has_file=0 AND status IN ('queued', 'searching', 'downloading', 'failed');

-- Drop blocklist so a fresh search can pick a different release (e.g. TPB not YTS)
DELETE FROM grab_blocklist;
SQL

echo "  automation.enabled = false"
echo "  pending/submitting jobs → manually_resolved"
echo "  movies/episodes reset to wanted"
echo "  grab_blocklist cleared"

docker start boxarr 2>/dev/null || echo "  start boxarr manually when ready"

echo
echo "=== Before cooldown ends, fix the root cause ==="
cat <<'EOF'
1. Reinstall magnet proxy (strips bad YTS magnets):
     curl -fsSL .../install-prowlarr-proxy.sh | sudo bash
2. Boxarr → Settings → Prowlarr URL:
     http://boxarr-prowlarr-proxy:9697
3. Prowlarr → disable YTS/YIFY, enable The Pirate Bay only
4. Do NOT retry grabs until TorBox cooldown shows Clear in Boxarr
5. After cooldown: pick a TPB release manually (not YTS)
EOF

if [[ -n "${TB_COOLDOWN}" ]] && [[ "${TB_STATE}" == "active" ]]; then
  echo
  echo "Cooldown until: ${TB_COOLDOWN}"
  echo "Wait for Boxarr dashboard 'TorBox cooldown' to show Clear before searching."
fi
