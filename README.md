# Boxarr + TorBox on ZimaOS

One-shot installer for a **Plex request stack** on [ZimaOS](https://www.zimaspace.com/):

| Component | Role |
|-----------|------|
| **Boxarr** | Sonarr/Radarr-compatible API for Seerr |
| **Prowlarr** | Torrent indexers |
| **TorBox** | Cloud downloads via host **rclone** mount |
| **Seerr** | Friend requests (optional) |
| **FlareSolverr** | Cloudflare bypass for Prowlarr indexers (optional tag) |

Designed for ZimaOS where **Docker FUSE propagation fails** — TorBox is mounted on the **host** with **systemd** so it survives reboots.

## Requirements

- ZimaOS with **Developer Mode** and **SSH** (run as `root`, not the web terminal)
- [TorBox](https://torbox.app) API key
- [TMDB](https://www.themoviedb.org/settings/api) API key (v4 read token)
- Plex (optional but typical)

## Fresh install (from scratch)

SSH into ZimaOS and run:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install.sh -o /tmp/install.sh
sed -i 's/\r$//' /tmp/install.sh
chmod +x /tmp/install.sh
sudo TORBOX_API_KEY='YOUR_TORBOX_KEY' TMDB_API_KEY='YOUR_TMDB_KEY' bash /tmp/install.sh
```

Without Seerr on first run:

```bash
sudo INSTALL_SEERR=0 TORBOX_API_KEY='...' TMDB_API_KEY='...' bash /tmp/install.sh
```

The installer:

1. Creates folders under `/DATA` (or `/media/Storage`)
2. Writes `rclone.conf` for TorBox WebDAV
3. Mounts TorBox at `/DATA/Media/torbox`
4. Installs **`boxarr-torbox-mount.service`** (rclone **starts on boot**)
5. Starts Boxarr, Prowlarr, Prowlarr torrent proxy, FlareSolverr, and Seerr

### After install

| Service | URL |
|---------|-----|
| Boxarr | `http://<zima-ip>:8181` |
| Prowlarr | `http://<zima-ip>:9696` |
| Seerr | `http://<zima-ip>:5055` |

**Prowlarr:** add torrent indexers (The Pirate Bay recommended; YTS magnets often break).

**Boxarr:** Settings → TorBox → paste API key if empty. Prowlarr URL is pre-set to the torrent proxy.

**Seerr:** connect Boxarr as both Sonarr and Radarr — see **[docs/seerr-setup.md](docs/seerr-setup.md)** for full steps.

Quick version:

| | Sonarr | Radarr |
|---|--------|--------|
| **API key** | From install output, Boxarr → Settings → Requests, or `show-seerr-key.sh` | *(same key)* |
| **URL (option 2)** | `http://boxarr:8080/sonarr` | `http://boxarr:8080/radarr` |
| **Host / port / base (option 1)** | `boxarr` · `8080` · `/sonarr` | `boxarr` · `8080` · `/radarr` |

Set default quality profile + root folder on each, then click **Test**.

**Plex volumes:**

- `/DATA/Media/library` → `/mnt/library`
- `/DATA/Media/torbox` → `/mnt/torbox`

## Boot behavior

| What | How |
|------|-----|
| TorBox mount | `systemd` → `boxarr-torbox-mount.service` |
| ZimaOS /DATA delay | Start script waits up to 3 min for `rclone.conf` |
| Cron fallback | `/etc/cron.d/boxarr-torbox-mount` retries 90s after reboot |
| Docker stack | `docker compose up -d` in `/DATA/AppData/boxarr-stack` |

`install.sh` and `enable-rclone-startup.sh` both install:

- `/DATA/AppData/boxarr-rclone/boxarr-torbox-mount-start.sh` — boot wrapper
- `/etc/systemd/system/boxarr-torbox-mount.service` — enabled on boot
- `/etc/cron.d/boxarr-torbox-mount` — ZimaOS safety net

After reboot (wait ~2 minutes for /DATA + cron):

```bash
sudo systemctl status boxarr-torbox-mount
ls /DATA/Media/torbox
cd /DATA/AppData/boxarr-stack && sudo docker compose up -d
```

Re-apply boot setup on an existing install:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/enable-rclone-startup.sh -o /tmp/enable-rclone-startup.sh
sudo bash /tmp/enable-rclone-startup.sh
```

## Helper scripts

All scripts live in [`scripts/`](scripts/). Run as root on ZimaOS.

| Script | Purpose |
|--------|---------|
| [`install.sh`](scripts/install.sh) | Full one-shot install |
| [`enable-rclone-startup.sh`](scripts/enable-rclone-startup.sh) | Install/enable rclone systemd service |
| [`restart-rclone-mount.sh`](scripts/restart-rclone-mount.sh) | Remount TorBox |
| [`fix-stack.sh`](scripts/fix-stack.sh) | Repair permissions, mount, compose |
| [`diagnose.sh`](scripts/diagnose.sh) | Quick health check |
| [`clear-boxarr-pause.sh`](scripts/clear-boxarr-pause.sh) | Diagnose/clear Boxarr paused state (cooldown, daily cap, backoff) |
| [`clear-boxarr-cooldown.sh`](scripts/clear-boxarr-cooldown.sh) | Alias for `clear-boxarr-pause.sh` |
| [`freeze-boxarr-cooldown.sh`](scripts/freeze-boxarr-cooldown.sh) | Stop Boxarr retries during active TorBox cooldown |
| [`show-seerr-key.sh`](scripts/show-seerr-key.sh) | Print Seerr API key + connection cheat sheet |
| [`test-torbox-submit.sh`](scripts/test-torbox-submit.sh) | Test TorBox API magnet submit |
| [`diagnose-boxarr-magnet.sh`](scripts/diagnose-boxarr-magnet.sh) | Diagnose TorBox invalid magnet errors |
| [`install-prowlarr-proxy.sh`](scripts/install-prowlarr-proxy.sh) | Reinstall Prowlarr torrent proxy |
| [`install-flaresolverr.sh`](scripts/install-flaresolverr.sh) | Start FlareSolverr + configure Prowlarr (docker run) |
| [`repair-compose.sh`](scripts/repair-compose.sh) | Restore or regenerate broken docker-compose.yml |
| [`regenerate-compose.sh`](scripts/regenerate-compose.sh) | Rebuild compose from Boxarr/Prowlarr data (no backup needed) |

Example:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/diagnose.sh | sudo bash
```

## Common issues

### TorBox mount empty after reboot

```bash
sudo systemctl restart boxarr-torbox-mount
# or
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/restart-rclone-mount.sh | sudo bash
```

### Boxarr shows "paused" but TorBox dashboard is clear

Boxarr can look paused for several reasons:

1. **Cached cooldown** — `torbox.cooldown_until` in SQLite (survives restarts)
2. **Learned daily cap** — `torbox.daily_cap` (reset in TorBox view → *Reset learned limits*)
3. **Expired TorBox API string** — `/user/me` may return an old `cooldown_until`; Boxarr UI treats any non-empty value as paused even after it expires
4. **In-memory 429 backoff** — cleared by restarting the `boxarr` container

Run the diagnostic/clear script:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/clear-boxarr-pause.sh -o /tmp/clear-boxarr-pause.sh
sudo bash /tmp/clear-boxarr-pause.sh
```

Then hard-refresh Boxarr in your browser. If grabs still fail, test TorBox directly:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/test-torbox-submit.sh | sudo bash
```

### Boxarr hit a real ~24h TorBox cooldown (downloads paused, DMM still works)

Invalid magnet retries and auto-search can trigger a **real** TorBox account cooldown (~24h). DMM may still work for cached torrents; **new Boxarr submits are blocked** until it clears.

**Stop the retry storm now:**

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/freeze-boxarr-cooldown.sh -o /tmp/freeze-boxarr-cooldown.sh
sudo bash /tmp/freeze-boxarr-cooldown.sh
```

**Before cooldown ends**, fix magnets (proxy + disable YTS, enable TPB). **Do not search or grab** in Boxarr until the dashboard shows **TorBox cooldown: Clear**.


### Invalid Magnet Link (TorBox rejects magnet)

TorBox returns *"Your torrent could not be added because the magnet link is invalid"* when the indexer sends a bad magnet — **YTS is the usual culprit**. TPB works reliably.

**1. Diagnose:**

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/diagnose-boxarr-magnet.sh -o /tmp/diagnose-boxarr-magnet.sh
sudo bash /tmp/diagnose-boxarr-magnet.sh
```

**2. Reinstall the magnet-sanitizing proxy** (strips YTS magnets, rebuilds valid btih hashes):

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-prowlarr-proxy.sh -o /tmp/install-prowlarr-proxy.sh
sudo bash /tmp/install-prowlarr-proxy.sh
```

**3. In Boxarr → Settings → Prowlarr**, set URL to `http://boxarr-prowlarr-proxy:9697` and save.

**4. In Prowlarr → Indexers:** enable **The Pirate Bay**, disable **YTS/YIFY**.

**5. Retry the grab** — pick a **TPB** release, not YTS.

### Prowlarr search returns HTTP 400

Boxarr searches with Usenet indexer IDs. The torrent proxy fixes this — Boxarr Prowlarr URL must be `http://boxarr-prowlarr-proxy:9697`.

### “All indexer proxies are unavailable due to failures”

Usually a broken **FlareSolverr** entry in Prowlarr → Settings → Indexer Proxies.

**Repair the stack FlareSolverr service:**

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/install-flaresolverr.sh | sudo bash
```

For TPB-only setups you can delete the proxy in Prowlarr instead — TPB does not need FlareSolverr.

Full guide: **[docs/prowlarr-troubleshooting.md](docs/prowlarr-troubleshooting.md)**

## Host paths

| Path | Contents |
|------|----------|
| `/DATA/AppData/boxarr-stack` | `docker-compose.yml` |
| `/DATA/AppData/boxarr` | Boxarr DB + config |
| `/DATA/AppData/boxarr-rclone` | `rclone.conf`, mount logs |
| `/DATA/AppData/prowlarr` | Prowlarr config |
| `/DATA/AppData/seerr` | Seerr config |
| `/DATA/Media/torbox` | TorBox rclone mount |
| `/DATA/Media/library` | Plex library (movies/tv/anime) |

## Dedicated repository

This stack is published on the **`boxarr-zimaos`** branch of [killamfkr/warpbox](https://github.com/killamfkr/warpbox/tree/boxarr-zimaos).

To mirror it to a standalone repo `killamfkr/boxarr-zimaos`:

1. On GitHub: **New repository** → `boxarr-zimaos` (empty, no README)
2. On your machine:

```bash
git clone https://github.com/killamfkr/warpbox.git -b boxarr-zimaos boxarr-zimaos
cd boxarr-zimaos
git remote set-url origin https://github.com/killamfkr/boxarr-zimaos.git
git push -u origin boxarr-zimaos:main
```

Then change script URLs from `warpbox/boxarr-zimaos` to `boxarr-zimaos/main` if you prefer.

## Related

- [Warpbox](https://github.com/killamfkr/warpbox) — TorBox WebDAV proxy (different project)
- [Boxarr](https://github.com/radaiko/Boxarr) — upstream app

## License

Install scripts: MIT. Boxarr, Prowlarr, Seerr, and rclone are their respective projects.
