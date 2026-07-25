#!/usr/bin/env python3
"""Minimal Prowlarr proxy for torrent-only Boxarr setups.

Boxarr always searches Prowlarr with indexerIds=-1 (all Usenet indexers).
On a torrent-only Prowlarr that returns HTTP 400. This proxy rewrites only that
query parameter to indexerIds=-2 (all torrent indexers). Everything else passes
through unchanged — no magnet or release rewriting.

Optional: set SANITIZE_MAGNETS=1 to enable legacy magnet cleanup (off by default).

Usage:
  PROWLARR_UPSTREAM=http://127.0.0.1:9696 python3 prowlarr-torrent-proxy.py
  # Boxarr Settings → Prowlarr URL: http://boxarr-prowlarr-proxy:9697
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("PROWLARR_UPSTREAM", "http://127.0.0.1:9696").rstrip("/")
LISTEN_HOST = os.environ.get("PROWLARR_PROXY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("PROWLARR_PROXY_PORT", "9697"))
SANITIZE_MAGNETS = os.environ.get("SANITIZE_MAGNETS", "0").strip().lower() in (
    "1",
    "true",
    "yes",
)

_HEX_HASH_RE = re.compile(r"^[a-f0-9]{40}$", re.IGNORECASE)
_BTIH_RE = re.compile(
    r"xt=urn:btih:([a-f0-9]{40}|[a-z2-7]{32})",
    re.IGNORECASE,
)


def rewrite_search_path(path: str) -> str:
    parsed = urllib.parse.urlparse(path)
    if not parsed.path.endswith("/api/v1/search"):
        return path
    q = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    ids = q.get("indexerIds", [])
    if ids == ["-1"] or ids == []:
        q["indexerIds"] = ["-2"]  # Boxarr asked for Usenet → use torrent indexers
    new_query = urllib.parse.urlencode(q, doseq=True)
    return urllib.parse.urlunparse(parsed._replace(query=new_query))


def is_search_path(path: str) -> bool:
    return urllib.parse.urlparse(path).path.endswith("/api/v1/search")


def valid_magnet(url: str) -> bool:
    u = (url or "").strip()
    if not u.lower().startswith("magnet:?"):
        return False
    return bool(_BTIH_RE.search(u))


def build_magnet(info_hash: str, title: str = "") -> str:
    h = (info_hash or "").strip().lower()
    if not _HEX_HASH_RE.fullmatch(h):
        return ""
    magnet = f"magnet:?xt=urn:btih:{h}"
    if title:
        magnet += "&dn=" + urllib.parse.quote(title)
    return magnet


def sanitize_release(item: dict) -> bool:
    if not isinstance(item, dict):
        return False
    if item.get("protocol") not in ("torrent", "", None):
        return False

    magnet = (item.get("magnetUrl") or "").strip()
    info_hash = (item.get("infoHash") or "").strip().lower()
    title = (item.get("title") or "").strip()
    changed = False

    if magnet and not valid_magnet(magnet):
        item["magnetUrl"] = ""
        changed = True
        magnet = ""

    if not magnet and info_hash:
        rebuilt = build_magnet(info_hash, title)
        if rebuilt:
            item["magnetUrl"] = rebuilt
            changed = True

    return changed


def maybe_sanitize_search_results(body: bytes) -> bytes:
    if not SANITIZE_MAGNETS:
        return body
    try:
        results = json.loads(body)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return body
    if not isinstance(results, list):
        return body

    changed = False
    for item in results:
        if sanitize_release(item):
            changed = True
    if not changed:
        return body
    return json.dumps(results, separators=(",", ":")).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _proxy(self) -> None:
        path = rewrite_search_path(self.path)
        headers = {
            k: v
            for k, v in self.headers.items()
            if k.lower() not in ("host", "connection", "content-length")
        }
        req = urllib.request.Request(UPSTREAM + path, headers=headers, method=self.command)
        if self.command in ("POST", "PUT", "PATCH"):
            length = int(self.headers.get("Content-Length", 0))
            req.data = self.rfile.read(length) if length else None
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = resp.read()
                if resp.status == 200 and is_search_path(path):
                    body = maybe_sanitize_search_results(body)
                self.send_response(resp.status)
                skip = {"transfer-encoding", "connection", "content-length"}
                for k, v in resp.headers.items():
                    if k.lower() not in skip:
                        self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except urllib.error.HTTPError as e:
            body = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "text/plain"))
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_GET(self) -> None:
        self._proxy()

    def do_POST(self) -> None:
        self._proxy()

    def do_PUT(self) -> None:
        self._proxy()

    def do_DELETE(self) -> None:
        self._proxy()


def main() -> None:
    httpd = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    mode = "rewrite-only" if not SANITIZE_MAGNETS else "rewrite+sanitize"
    print(
        f"Prowlarr proxy ({mode}) on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}",
        flush=True,
    )
    httpd.serve_forever()


if __name__ == "__main__":
    main()
