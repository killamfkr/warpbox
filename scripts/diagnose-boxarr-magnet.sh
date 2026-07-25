#!/usr/bin/env bash
# Diagnose TorBox "Invalid Magnet Link" failures in Boxarr.
# Run as root on ZimaOS:
#   curl -fsSL .../diagnose-boxarr-magnet.sh | sudo bash

set -u

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  echo "ERROR: run as root — use: curl -fsSL .../diagnose-boxarr-magnet.sh | sudo bash" >&2
  exit 1
fi

BASE="/DATA"
DB="${BASE}/AppData/boxarr/boxarr.db"
if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  BASE="/media/Storage"
  DB="${BASE}/AppData/boxarr/boxarr.db"
fi

echo "=== Boxarr magnet / TorBox submit diagnostics ==="
echo "db: ${DB}"
echo

if [[ ! -f "${DB}" ]]; then
  echo "MISSING boxarr.db at ${DB}"
  exit 1
fi

echo "=== failed torrent jobs (last 5) ==="
sqlite3 -header -column "${DB}" "
SELECT id, substr(nzb_name,1,50) AS release,
       CASE
         WHEN torrent_magnet = '' THEN '(empty)'
         WHEN torrent_magnet LIKE 'magnet:%' THEN substr(torrent_magnet,1,60) || '...'
         ELSE substr(torrent_magnet,1,60)
       END AS magnet_preview,
       CASE WHEN length(torrent_file) > 0 THEN length(torrent_file) || ' bytes' ELSE '(none)' END AS torrent_file,
       substr(fail_message,1,80) AS error
FROM jobs
WHERE protocol = 'torrent' AND state = 'failed'
ORDER BY id DESC
LIMIT 5;
" 2>/dev/null || echo "sqlite query failed"
echo

echo "=== TorBox API key configured? ==="
sqlite3 "${DB}" "SELECT key, CASE WHEN length(value)>4 THEN substr(value,1,4)||'...' ELSE '(empty)' END FROM settings WHERE key LIKE 'torbox%';" 2>/dev/null || true
echo

echo "=== Prowlarr proxy running? ==="
if docker ps --format '{{.Names}}' | grep -qx boxarr-prowlarr-proxy; then
  echo "OK  boxarr-prowlarr-proxy"
  docker logs boxarr-prowlarr-proxy --tail 3 2>&1 || true
else
  echo "MISS boxarr-prowlarr-proxy — install with install-prowlarr-proxy.sh"
fi
echo

echo "=== sample YTS search via proxy (magnet sanity) ==="
PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${BASE}/AppData/prowlarr/config.xml" 2>/dev/null | head -1 || true)"
if [[ -n "${PKEY}" ]] && docker ps --format '{{.Names}}' | grep -qx boxarr-prowlarr-proxy; then
  NET="boxarr-net"
  docker network inspect "${NET}" >/dev/null 2>&1 || NET="bridge"
  docker run --rm --network "${NET}" curlimages/curl:latest -sf \
    -H "X-Api-Key: ${PKEY}" \
    "http://boxarr-prowlarr-proxy:9697/api/v1/search?query=matrix%201999&type=movie&categories=2000&indexerIds=-2&limit=3" \
    2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
for r in data[:3]:
    m = (r.get('magnetUrl') or '')[:70]
    d = (r.get('downloadUrl') or '')[:70]
    h = r.get('infoHash') or ''
    ok = m.lower().startswith('magnet:?') and 'btih:' in m.lower()
    print(f\"{r.get('indexer','?'):12} magnet_ok={ok} hash={h[:12]}...\")
    print(f\"  magnet:   {m or '(empty)'}\")
    print(f\"  download: {d or '(empty)'}\")
" 2>/dev/null || echo "search test failed (check Prowlarr indexers)"
else
  echo "skipped (need prowlarr API key + proxy container)"
fi
echo

echo "=== recent boxarr TorBox errors ==="
docker logs boxarr --tail 40 2>&1 | grep -iE 'magnet|torrent submission|torbox' | tail -10 || echo "(none)"
echo

cat <<'EOF'
=== what to do ===
1. Update the Prowlarr proxy (fixes bad magnets from YTS/TPB):
   curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/cursor/fix-invalid-magnet-proxy-1b99/scripts/install-prowlarr-proxy.sh | sudo bash

2. In Boxarr → Movies → The Dink → Search releases → try a release from
   The Pirate Bay (not YTS) if available, or one marked cached.

3. Test with an older known-good title (e.g. The Matrix 1999) to confirm
   end-to-end TorBox submission works.

4. Clear failed history and retry:
   sqlite3 /DATA/AppData/boxarr/boxarr.db "DELETE FROM jobs WHERE state='failed';"
   docker restart boxarr
EOF
