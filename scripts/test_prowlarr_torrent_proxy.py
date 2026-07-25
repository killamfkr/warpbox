#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("proxy", ROOT / "prowlarr-torrent-proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class ProxyRewriteTests(unittest.TestCase):
    def test_rewrites_usenet_to_torrent(self):
        out = proxy.rewrite_search_path(
            "/api/v1/search?query=test&type=search&indexerIds=-1"
        )
        self.assertIn("indexerIds=-2", out)

    def test_leaves_explicit_torrent_ids(self):
        path = "/api/v1/search?query=test&indexerIds=5"
        self.assertEqual(proxy.rewrite_search_path(path), path)

    def test_passes_through_non_search(self):
        path = "/api/v1/indexer"
        self.assertEqual(proxy.rewrite_search_path(path), path)


class ProxySanitizeTests(unittest.TestCase):
    def test_no_sanitize_by_default(self):
        item = {
            "protocol": "torrent",
            "indexer": "YTS",
            "magnetUrl": "magnet:?dn=broken",
            "infoHash": "c" * 40,
        }
        body = proxy.maybe_sanitize_search_results(
            __import__("json").dumps([item]).encode()
        )
        self.assertIn(b"broken", body)

    def test_sanitize_when_enabled(self):
        proxy.SANITIZE_MAGNETS = True
        try:
            item = {
                "protocol": "torrent",
                "magnetUrl": "magnet:?dn=broken",
                "infoHash": "c" * 40,
                "title": "Movie",
            }
            body = proxy.maybe_sanitize_search_results(
                __import__("json").dumps([item]).encode()
            )
            self.assertIn(b"urn:btih:", body)
            self.assertNotIn(b"dn=broken", body)
        finally:
            proxy.SANITIZE_MAGNETS = False


if __name__ == "__main__":
    unittest.main()
