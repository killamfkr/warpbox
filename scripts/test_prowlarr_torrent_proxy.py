#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("proxy", ROOT / "prowlarr-torrent-proxy.py")
proxy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy)


class ProxySanitizeTests(unittest.TestCase):
    def test_valid_hex_magnet(self):
        h = "a" * 40
        self.assertTrue(proxy.valid_magnet(f"magnet:?xt=urn:btih:{h}"))

    def test_rejects_missing_hash(self):
        self.assertFalse(proxy.valid_magnet("magnet:?dn=test"))

    def test_rejects_short_hash(self):
        self.assertFalse(proxy.valid_magnet("magnet:?xt=urn:btih:abc"))

    def test_normalizes_base32_hash(self):
        # Ubuntu 22.04 ISO hash in base32
        b32 = "CI6PQXATNOQ6D4FBM7ID7P3ERVMKBTQY"
        hexh = proxy.normalize_info_hash(b32)
        self.assertEqual(len(hexh), 40)
        self.assertTrue(proxy.valid_magnet(f"magnet:?xt=urn:btih:{b32}"))

    def test_strips_yts_magnet_when_download_present(self):
        item = {
            "protocol": "torrent",
            "indexer": "YTS",
            "magnetUrl": "magnet:?xt=urn:btih:" + ("b" * 40),
            "downloadUrl": "http://prowlarr/dl/1",
            "infoHash": "b" * 40,
            "title": "Movie 2020",
        }
        self.assertTrue(proxy.sanitize_release(item))
        self.assertEqual(item["magnetUrl"], "")

    def test_rebuilds_from_infohash_when_magnet_invalid(self):
        item = {
            "protocol": "torrent",
            "indexer": "The Pirate Bay",
            "magnetUrl": "magnet:?dn=broken",
            "infoHash": "c" * 40,
            "title": "Movie",
        }
        self.assertTrue(proxy.sanitize_release(item))
        self.assertIn("urn:btih:" + ("c" * 40), item["magnetUrl"])

    def test_clears_magnet_when_hash_mismatch(self):
        item = {
            "protocol": "torrent",
            "indexer": "TPB",
            "magnetUrl": "magnet:?xt=urn:btih:" + ("d" * 40),
            "infoHash": "e" * 40,
            "title": "Movie",
        }
        self.assertTrue(proxy.sanitize_release(item))
        self.assertIn("urn:btih:" + ("e" * 40), item["magnetUrl"])


if __name__ == "__main__":
    unittest.main()
