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

### Fix B — you use TPB / simple indexers only

You usually **do not need** FlareSolverr for The Pirate Bay.

1. Open Prowlarr → **Settings** → **Indexer Proxies**
2. Open each entry (often FlareSolverr)
3. Click **Delete** (or disable if you prefer)
4. **System** → **Health** — warning should clear after a minute

Then test indexers: **Indexers** → select indexer → **Test**.

### Fix B — you need FlareSolverr (Cloudflare indexers)

Only if an indexer explicitly requires it.

1. Run FlareSolverr on the same Docker network as Prowlarr:

```bash
docker run -d \
  --name flaresolverr \
  --restart unless-stopped \
  --network boxarr-net \
  -e LOG_LEVEL=info \
  flaresolverr/flaresolverr
```

2. Prowlarr → **Settings** → **Indexer Proxies** → edit FlareSolverr:
   - **Host:** `flaresolverr` (no `http://`)
   - **Port:** `8191`
   - **Tags:** e.g. `flaresolverr` — **required** or Prowlarr disables the proxy
3. On each indexer that needs it → **Tags** → add the same tag (e.g. `flaresolverr`)
4. **Test** the proxy, then **Test** the indexer

Verify from host:

```bash
docker run --rm --network boxarr-net curlimages/curl:latest -sf http://flaresolverr:8191/ | head -c 200
```

Should return JSON with `"status":"ok"`.

### Fix C — wrong URL format

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
