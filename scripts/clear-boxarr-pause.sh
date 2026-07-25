#!/usr/bin/env bash
# Diagnose and clear Boxarr "paused" state when TorBox cooldown looks clear.
#
# Boxarr can show "paused" even after cooldown clears because:
#   - torbox.cooldown_until is cached in SQLite (survives restarts)
#   - torbox.daily_cap is a learned ceiling (UI only; reset via TorBox view)
#   - TorBox /user/me may return an expired cooldown_until string (UI bug:
#     Boxarr treats any non-empty value as "downloads paused")
#   - in-memory submit backoff from a recent 429 (cleared by restarting boxarr)
#
# Run on ZimaOS:
#   sudo bash clear-boxarr-pause.sh           # diagnose + clear stale Boxarr state
#   sudo bash clear-boxarr-pause.sh --force   # clear Boxarr cache even if TorBox cooldown active
#   sudo bash clear-boxarr-pause.sh --dry-run # diagnose only, no changes

set -euo pipefail

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

FORCE=0
DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --force) FORCE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "Unknown option: ${arg} (try --help)" >&2; exit 1 ;;
  esac
done

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
[[ -d /media/Storage ]] && [[ ! -d /DATA ]] && DB="/media/Storage/AppData/boxarr/boxarr.db"

[[ -f "${DB}" ]] || { echo "FAIL: boxarr.db not found at ${DB}"; exit 1; }

read_setting() {
  sqlite3 "${DB}" "SELECT value FROM settings WHERE key='$1' LIMIT 1;" 2>/dev/null || true
}

KEY="$(read_setting torbox.token)"
CACHED_CD="$(read_setting torbox.cooldown_until)"
DAILY_CAP="$(read_setting torbox.daily_cap)"
AUTOMATION="$(read_setting automation.enabled)"
MAX_HOURLY="$(read_setting limit.max_create_per_hour)"

echo "=== Boxarr pause / throttle state ==="
echo "db: ${DB}"
echo "torbox.cooldown_until (cached): ${CACHED_CD:-"(none)"}"
echo "torbox.daily_cap (learned):     ${DAILY_CAP:-0}"
echo "automation.enabled:             ${AUTOMATION:-"(env default)"}"
echo "limit.max_create_per_hour:      ${MAX_HOURLY:-"(env default)"}"
echo

# Count recent submissions for hourly-cap context.
GRABS_HOUR="$(sqlite3 "${DB}" \
  "SELECT COUNT(*) FROM jobs WHERE submitted_at IS NOT NULL AND submitted_at != '' AND datetime(submitted_at) >= datetime('now', '-1 hour') AND protocol='usenet';" \
  2>/dev/null || echo "?")"
GRABS_TODAY="$(sqlite3 "${DB}" \
  "SELECT COUNT(*) FROM jobs WHERE submitted_at IS NOT NULL AND submitted_at != '' AND date(submitted_at) = date('now');" \
  2>/dev/null || echo "?")"
echo "grabs last hour (usenet): ${GRABS_HOUR}"
echo "grabs today (all):        ${GRABS_TODAY}"
echo

TB_COOLDOWN=""
TB_COOLDOWN_STATE="none"
if [[ -n "${KEY}" ]]; then
  echo "=== TorBox account (GET /user/me) ==="
  ME="$(curl -sf -H "Authorization: Bearer ${KEY}" \
    "https://api.torbox.app/v1/api/user/me?settings=false" 2>&1)" || {
    echo "WARN: could not reach TorBox API"
    ME=""
  }
  if [[ -n "${ME}" ]]; then
    eval "$(echo "${ME}" | python3 -c "
import json, sys
from datetime import datetime, timezone

d = json.load(sys.stdin).get('data', {})
cd = (d.get('cooldown_until') or '').strip()
print('plan=%r' % d.get('plan'))
print('subscribed=%r' % d.get('is_subscribed'))
print('cooldown_raw=%r' % cd)
if not cd:
    print('cooldown_state=none')
    print('cooldown_active=')
else:
    try:
        until = datetime.fromisoformat(cd.replace('Z', '+00:00'))
        if until.tzinfo is None:
            until = until.replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        if until > now:
            print('cooldown_state=active')
            print('cooldown_active=%r' % cd)
        else:
            print('cooldown_state=expired')
            print('cooldown_active=')
    except Exception:
        print('cooldown_state=unparseable')
        print('cooldown_active=%r' % cd)
" 2>/dev/null || true)"
    TB_COOLDOWN="${cooldown_raw:-}"
    TB_COOLDOWN_STATE="${cooldown_state:-unknown}"
    echo "plan: ${plan:-?}  subscribed: ${subscribed:-?}"
    echo "torbox cooldown_until: ${TB_COOLDOWN:-"(none)"}"
    case "${TB_COOLDOWN_STATE}" in
      active)
        echo "status: ACTIVE cooldown — TorBox is still throttling this account"
        ;;
      expired)
        echo "status: EXPIRED cooldown string — torbox.app may look clear but Boxarr UI still shows 'downloads paused'"
        echo "        Submissions should work; restart boxarr after clearing Boxarr cache below."
        ;;
      none)
        echo "status: no cooldown on TorBox account"
        ;;
      *)
        echo "status: could not parse cooldown (${TB_COOLDOWN_STATE})"
        ;;
    esac
  fi
  echo
elif [[ -z "${KEY}" ]]; then
  echo "WARN: no torbox.token in Boxarr DB — cannot query TorBox API"
  echo
fi

echo "=== Why Boxarr may still look paused ==="
REASONS=0
if [[ -n "${CACHED_CD}" ]]; then
  echo "  • Boxarr cached torbox.cooldown_until=${CACHED_CD}"
  REASONS=$((REASONS + 1))
fi
if [[ -n "${DAILY_CAP}" ]] && [[ "${DAILY_CAP}" != "0" ]]; then
  echo "  • Learned daily cap torbox.daily_cap=${DAILY_CAP} (UI label only; click Reset learned limits in TorBox view)"
  REASONS=$((REASONS + 1))
fi
if [[ "${TB_COOLDOWN_STATE}" == "active" ]]; then
  echo "  • TorBox account cooldown active until ${TB_COOLDOWN}"
  REASONS=$((REASONS + 1))
fi
if [[ "${TB_COOLDOWN_STATE}" == "expired" ]]; then
  echo "  • TorBox API returns expired cooldown_until=${TB_COOLDOWN} — Boxarr UI bug shows 'paused' though grabs work"
  REASONS=$((REASONS + 1))
fi
if [[ -n "${MAX_HOURLY}" ]] && [[ "${MAX_HOURLY}" != "0" ]] && [[ "${GRABS_HOUR}" != "?" ]]; then
  if [[ "${GRABS_HOUR}" -ge "${MAX_HOURLY}" ]]; then
    echo "  • Hourly create cap reached (${GRABS_HOUR}/${MAX_HOURLY} usenet grabs this hour)"
    REASONS=$((REASONS + 1))
  fi
fi
if [[ "${REASONS}" -eq 0 ]]; then
  echo "  • No obvious throttle flags in DB or TorBox API."
  echo "  • If UI still says paused: restart boxarr (clears in-memory 429 backoff) and hard-refresh the browser."
fi
echo

if [[ "${TB_COOLDOWN_STATE}" == "active" ]] && [[ "${FORCE}" -eq 0 ]]; then
  echo "FAIL: TorBox account cooldown is still active until ${TB_COOLDOWN}."
  echo "      Wait it out, or use --force to clear Boxarr's cache anyway (submits will still fail until TorBox clears)."
  exit 1
fi

NEEDS_CLEAR=0
[[ -n "${CACHED_CD}" ]] && NEEDS_CLEAR=1
[[ -n "${DAILY_CAP}" ]] && [[ "${DAILY_CAP}" != "0" ]] && NEEDS_CLEAR=1

if [[ "${NEEDS_CLEAR}" -eq 0 ]] && [[ "${FORCE}" -eq 0 ]]; then
  echo "Boxarr DB has no cached cooldown or daily cap to clear."
  if [[ "${TB_COOLDOWN_STATE}" == "expired" ]]; then
    echo
    echo "TorBox returned an expired cooldown string — the UI can still show paused."
    echo "Restart boxarr and hard-refresh Boxarr in your browser:"
    if docker ps --format '{{.Names}}' | grep -qx boxarr; then
      if [[ "${DRY_RUN}" -eq 1 ]]; then
        echo "  (dry-run) would restart boxarr"
      else
        docker restart boxarr >/dev/null
        echo "  restarted boxarr"
      fi
    else
      echo "  sudo docker restart boxarr"
    fi
    echo "If the TorBox view still shows a cap, click 'Reset learned limits' there."
  elif docker ps --format '{{.Names}}' | grep -qx boxarr; then
    echo
    echo "Restarting boxarr to clear any in-memory submit backoff..."
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "  (dry-run) would restart boxarr"
    else
      docker restart boxarr >/dev/null
      echo "  restarted boxarr"
    fi
  fi
  echo
  echo "OK: nothing to delete from settings. Try a grab (prefer TPB over YTS)."
  exit 0
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "DRY-RUN: would delete torbox.cooldown_until and reset torbox.daily_cap to 0"
  if docker ps --format '{{.Names}}' | grep -qx boxarr; then
    echo "DRY-RUN: would restart boxarr"
  fi
  exit 0
fi

echo "=== Clearing Boxarr learned throttle state ==="
sqlite3 "${DB}" "DELETE FROM settings WHERE key='torbox.cooldown_until';"
echo "deleted torbox.cooldown_until"
sqlite3 "${DB}" "INSERT INTO settings(key,value) VALUES('torbox.daily_cap','0') ON CONFLICT(key) DO UPDATE SET value='0';"
echo "reset torbox.daily_cap to 0"

if docker ps --format '{{.Names}}' | grep -qx boxarr; then
  docker restart boxarr >/dev/null
  echo "restarted boxarr (clears in-memory 429 backoff)"
else
  echo "boxarr container not running — start it when ready"
fi

echo
echo "OK: Boxarr pause state cleared."
echo "  • Hard-refresh Boxarr in your browser (Ctrl+Shift+R)"
echo "  • TorBox view → Reset learned limits if the UI still shows a cap"
echo "  • Test: sudo bash test-torbox-submit.sh"
echo "  • Prefer TPB releases over YTS magnets"
