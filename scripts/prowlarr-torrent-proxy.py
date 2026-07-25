#!/usr/bin/env python3
"""Proxy Prowlarr for Boxarr on torrent-only setups.

Boxarr always searches with indexerIds=-1 (Usenet). Prowlarr returns HTTP 400
when no Usenet indexers exist. This proxy rewrites those searches to use
indexerIds=-2 (all torrent indexers) instead.

It also sanitizes torrent search results so Boxarr does not submit broken magnet
links to TorBox (which returns HTTP 400 "Invalid Magnet Link"). When a release
has a bad magnet but a downloadUrl or infoHash, the proxy clears the bad magnet
or rebuilds a proper magnet:?xt=urn:btih:… URI so Boxarr can fall back to
fetching the .torrent file when needed.

Usage:
  PROWLARR_UPSTREAM=http://127.0.0.1:9696 python3 prowlarr-torrent-proxy.py
  # Boxarr Settings → Prowlarr URL: http://host:9697
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

_INFO_HASH_RE = re.compile(r"^[a-f0-9]{40}$", re.IGNORECASE)


def rewrite_search_path(path: str) -> str:
    parsed = urllib.parse.urlparse(path)
    if not parsed.path.endswith("/api/v1/search"):
        return path
    q = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    ids = q.get("indexerIds", [])
    if ids == ["-1"] or ids == []:
        q["indexerIds"] = ["-2"]  # all torrent indexers
    new_query = urllib.parse.urlencode(q, doseq=True)
    return urllib.parse.urlunparse(parsed._replace(query=new_query))


def is_search_path(path: str) -> bool:
    return urllib.parse.urlparse(path).path.endswith("/api/v1/search")


def valid_magnet(url: str) -> bool:
    """TorBox expects a real magnet URI with a btih (or btmh) xt param."""
    u = (url or "").strip()
    if not u.lower().startswith("magnet:?"):
        return False
    lower = u.lower()
    return "xt=urn:btih:" in lower or "xt=urn:btmh:" in lower


def build_magnet(info_hash: str, title: str = "") -> str:
    h = (info_hash or "").strip().lower()
    if not _INFO_HASH_RE.fullmatch(h):
        return ""
    magnet = f"magnet:?xt=urn:btih:{h}"
    if title:
        magnet += "&dn=" + urllib.parse.quote(title)
    return magnet


def sanitize_release(item: dict) -> bool:
    """Fix one Prowlarr release dict. Returns True if modified."""
    if not isinstance(item, dict):
        return False
    if item.get("protocol") not in ("torrent", "", None):
        return False

    magnet = (item.get("magnetUrl") or "").strip()
    download = (item.get("downloadUrl") or "").strip()
    info_hash = (item.get("infoHash") or "").strip()
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
            magnet = rebuilt

    # If magnet is still empty but we have a Prowlarr download URL, leave
    # magnetUrl empty so Boxarr fetches the .torrent via downloadUrl.
    if not magnet and not download and info_hash:
        rebuilt = build_magnet(info_hash, title)
        if rebuilt:
            item["magnetUrl"] = rebuilt
            changed = True

    return changed


def sanitize_search_results(body: bytes) -> bytes:
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
                    body = sanitize_search_results(body)
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
    print(f"Prowlarr torrent proxy on {LISTEN_HOST}:{LISTEN_PORT} -> {UPSTREAM}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
