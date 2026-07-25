#!/usr/bin/env bash
# Patch existing boxarr docker-compose.yml for FUSE mount propagation.
# Usage: patch-boxarr-compose.sh /DATA/AppData/boxarr-stack/docker-compose.yml /DATA/Media/torbox

set -euo pipefail

COMPOSE="${1:?compose file}"
TORBOX="${2:?torbox mount path}"

[[ -f "${COMPOSE}" ]] || { echo "missing ${COMPOSE}" >&2; exit 1; }

if grep -q 'propagation: rshared' "${COMPOSE}"; then
  echo "compose already has rshared propagation"
  exit 0
fi

cp -a "${COMPOSE}" "${COMPOSE}.bak.$(date +%s)"

python3 - "${COMPOSE}" "${TORBOX}" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
torbox = sys.argv[2]
text = path.read_text()

def bind_block(source: str, target: str, propagation: str) -> str:
    return (
        "      - type: bind\n"
        f"        source: {source}\n"
        f"        target: {target}\n"
        "        bind:\n"
        f"          propagation: {propagation}\n"
    )

def sub_volume(text: str, host_path: str, container_path: str, propagation: str) -> str:
    block = bind_block(host_path, container_path, propagation)
    patterns = [
        rf'      - {re.escape(host_path)}:{re.escape(container_path)}\n',
        rf'      - "{re.escape(host_path)}:{re.escape(container_path)}"\n',
        rf'      - {re.escape(host_path)}:{re.escape(container_path)}\n',
    ]
    for pat in patterns:
        if re.search(pat, text):
            return re.sub(pat, block, text, count=1)
    return text

before = text
text = sub_volume(text, torbox, "/data", "rshared")
text = sub_volume(text, torbox, "/mnt/torbox", "rslave")

if text == before:
    print("WARN: could not find torbox volume lines to patch", file=sys.stderr)
    sys.exit(2)

# Ensure privileged mode for FUSE on ZimaOS
if "boxarr-rclone:" in text and "privileged:" not in text:
    text = re.sub(
        r"(  boxarr-rclone:\n    image: rclone/rclone:latest\n)",
        r"\1    privileged: true\n",
        text,
        count=1,
    )

path.write_text(text)
print(f"patched {path}")
PY
