#!/usr/bin/env bash
# Register FlareSolverr as a Prowlarr Indexer Proxy (with flaresolverr tag).
# Run as root after boxarr-prowlarr and flaresolverr containers are up.
#
# curl -fsSL .../configure-prowlarr-flaresolverr.sh | sudo bash

set -euo pipefail

die() { echo "FAIL: $*" >&2; exit 1; }
ok()  { echo "OK:  $*"; }
say() { echo "==> $*"; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || exec sudo -E bash "$0" "$@"

BASE="/DATA"
PROWLARR_CFG="${BASE}/AppData/prowlarr"
FLARE_HOST="${FLARESOLVERR_HOST:-http://flaresolverr:8191}"
PROWLARR_URL="${PROWLARR_URL:-http://127.0.0.1:9696}"
TAG_LABEL="${FLARESOLVERR_TAG:-flaresolverr}"

if [[ -d /media/Storage ]] && [[ ! -d /DATA ]]; then
  BASE="/media/Storage"
  PROWLARR_CFG="${BASE}/AppData/prowlarr"
fi

[[ -f "${PROWLARR_CFG}/config.xml" ]] || die "Prowlarr config missing — start boxarr-prowlarr first"

PKEY="$(sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "${PROWLARR_CFG}/config.xml" | head -1)"
[[ -n "${PKEY}" ]] || die "Prowlarr API key not found in config.xml"

say "Waiting for FlareSolverr at ${FLARE_HOST}"
ready=0
for _ in $(seq 1 30); do
  if docker run --rm --network boxarr-net curlimages/curl:latest -sf "${FLARE_HOST}/" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" -eq 1 ]] || die "FlareSolverr not reachable at ${FLARE_HOST} — run install-flaresolverr.sh"

api() {
  curl -sf -H "X-Api-Key: ${PKEY}" -H "Content-Type: application/json" "$@"
}

say "Ensuring Prowlarr tag: ${TAG_LABEL}"
TAG_ID="$(api "${PROWLARR_URL}/api/v1/tag" | python3 -c "
import json, sys
label = '${TAG_LABEL}'.lower()
for t in json.load(sys.stdin):
    if (t.get('label') or '').lower() == label:
        print(t['id'])
        break
" 2>/dev/null || true)"

if [[ -z "${TAG_ID}" ]]; then
  TAG_ID="$(api -X POST -d "{\"label\":\"${TAG_LABEL}\"}" "${PROWLARR_URL}/api/v1/tag" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")"
fi
[[ -n "${TAG_ID}" ]] || die "could not create Prowlarr tag"
ok "tag ${TAG_LABEL} id=${TAG_ID}"

say "Ensuring FlareSolverr indexer proxy in Prowlarr"
PROXY_JSON="$(api "${PROWLARR_URL}/api/v1/indexerproxy" 2>/dev/null || echo '[]')"
EXISTING_ID="$(echo "${PROXY_JSON}" | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if p.get('implementation') == 'FlareSolverr':
        print(p.get('id', ''))
        break
" 2>/dev/null || true)"

PAYLOAD="$(python3 -c "
import json
print(json.dumps({
    'name': 'FlareSolverr',
    'implementation': 'FlareSolverr',
    'configContract': 'FlareSolverrSettings',
    'enable': True,
    'tags': [int('${TAG_ID}')],
    'fields': [
        {'name': 'host', 'value': '${FLARE_HOST}'},
        {'name': 'requestTimeout', 'value': 60},
    ],
}))
")"

if [[ -n "${EXISTING_ID}" ]]; then
  api -X PUT -d "${PAYLOAD}" "${PROWLARR_URL}/api/v1/indexerproxy/${EXISTING_ID}" >/dev/null
  ok "updated FlareSolverr proxy id=${EXISTING_ID}"
else
  api -X POST -d "${PAYLOAD}" "${PROWLARR_URL}/api/v1/indexerproxy" >/dev/null
  ok "created FlareSolverr proxy"
fi

api -X POST -d "${PAYLOAD}" "${PROWLARR_URL}/api/v1/indexerproxy/test" >/dev/null 2>&1 \
  && ok "FlareSolverr proxy test passed" \
  || echo "WARN: proxy test failed — check System → Events in Prowlarr" >&2

echo
echo "Add tag '${TAG_LABEL}' to indexers that need Cloudflare bypass (e.g. 1337x)."
echo "TPB usually does not need this tag."
