# Prowlarr troubleshooting

## Two different “proxies” (do not confuse them)

| Name | What it is | Where configured |
|------|------------|------------------|
| **boxarr-prowlarr-proxy** | Small Python container for **Boxarr only** — rewrites Usenet searches to torrent indexers | Installed by `install.sh`; Boxarr → Settings → Prowlarr URL `http://boxarr-prowlarr-proxy:9697` |
| **Indexer Proxies** | FlareSolverr / SOCKS / HTTP proxies **inside Prowlarr** for Cloudflare-heavy indexers | Prowlarr → **Settings → Indexer Proxies** |

The health warning **“All indexer proxies are unavailable due to failures”** refers to **Indexer Proxies** in Prowlarr — **not** `boxarr-prowlarr-proxy`.

---

## “All indexer proxies are unavailable due to failures”

Prowlarr added an **Indexer Proxy** (usually **FlareSolverr**) that is failing its health check.

## Fix A — reinstall stack FlareSolverr (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-flaresolverr.sh | sudo bash
```

This adds `flaresolverr` to compose (if missing), starts the container, and registers it in Prowlarr with tag `flaresolverr`.

### Fix B — TPB only (no FlareSolverr needed)

You usually **do not need** FlareSolverr for The Pirate Bay.

1. Open Prowlarr → **Settings** → **Indexer Proxies**
2. Delete the FlareSolverr entry
3. **System** → **Health** — warning should clear after a minute

### Fix C — manual Prowlarr settings (FlareSolverr already running)

Stack container: `flaresolverr` on `boxarr-net` (installed by `install.sh`).

Prowlarr → **Settings → Indexer Proxies**:

- **Host:** `http://flaresolverr:8191`
- **Tags:** `flaresolverr` — add the same tag on Cloudflare indexers (e.g. 1337x)

Verify:

```bash
sudo docker run --rm --network boxarr-net curlimages/curl:latest -sf http://flaresolverr:8191/ | head -c 200
```

### Fix D — wrong URL format

Some Prowlarr versions want **hostname only**, not a full URL:

- ✓ `flaresolverr` port `8191`
- ✗ `http://flaresolverr:8191`

Check **System** → **Events** (filter Warnings) for the exact error (`Name or service not known`, connection refused, etc.).

---

## Boxarr can’t search / HTTP 400 from Prowlarr

That’s the **torrent proxy**, not Indexer Proxies.

```bash
# Is it running?
docker ps | grep boxarr-prowlarr-proxy

# Reinstall
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-prowlarr-proxy.sh | sudo bash
```

Boxarr → Settings → Prowlarr URL must be:

```text
http://boxarr-prowlarr-proxy:9697
```

**Not** `9696` (that’s Prowlarr directly, and Boxarr sends Usenet indexer IDs).

---

## Indexers unavailable (not proxies)

Separate warning: **“Indexers are unavailable due to failures”**

1. Prowlarr → **Indexers** → **Test** each one
2. **System** → **Events** for DNS/SSL/timeout errors
3. On ZimaOS, try disabling IPv6 in Prowlarr if DNS fails intermittently
4. Remove tags pointing at a broken FlareSolverr proxy

---

## Quick diagnostic

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/diagnose.sh | sudo bash
```

Checks `boxarr-prowlarr-proxy` container status and recent logs.
