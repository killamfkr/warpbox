# Seerr → Boxarr (Sonarr + Radarr)

Seerr talks to **Boxarr**, not real Sonarr/Radarr. Boxarr emulates both at `/sonarr` and `/radarr` on port **8080** (container port — not 8989/7878).

Use the **same API key** for both Sonarr and Radarr entries in Seerr.

## Get the API key (pick one)

### Option A — from the install script (easiest)

The installer prints a key at the end:

```text
Seerr API key: abc123...
```

That value was pre-seeded into Boxarr as `BOXARR_SEERR_API_KEYS`. Copy it into Seerr when adding both services.

### Option B — from Boxarr UI

1. Open Boxarr → **Settings** → **Requests**
2. Click **Generate** (or copy the existing Seerr API key)
3. Save

If the UI shows “Saved” but the key disappears (known Seerr/Boxarr quirk), use option C.

### Option C — from Boxarr database

```bash
sudo sqlite3 /DATA/AppData/boxarr/boxarr.db \
  "SELECT value FROM settings WHERE key='seerr.api_keys';"
```

On `/media/Storage` hosts, use `/media/Storage/AppData/boxarr/boxarr.db`.

Or run:

```bash
curl -fsSL https://raw.githubusercontent.com/killamfkr/warpbox/boxarr-zimaos/scripts/show-seerr-key.sh -o /tmp/show-seerr-key.sh
sudo bash /tmp/show-seerr-key.sh
```

## Add Sonarr + Radarr in Seerr (pick one)

Complete the Seerr wizard and connect Plex first, then **Settings → Services**.

### Option 1 — Hostname, port, and URL base (classic Seerr form)

Use this if Seerr shows separate **Hostname**, **Port**, and **URL Base** fields.

**Sonarr**

| Field | Value |
|-------|-------|
| Default Server | ✓ (required) |
| Server Name | `Boxarr Sonarr` (anything) |
| Hostname or IP | `boxarr` |
| Port | `8080` |
| URL Base | `/sonarr` |
| Use SSL | off |
| API Key | *(from options A/B/C above)* |

**Radarr**

| Field | Value |
|-------|-------|
| Default Server | ✓ (required) |
| Server Name | `Boxarr Radarr` (anything) |
| Hostname or IP | `boxarr` |
| Port | `8080` |
| URL Base | `/radarr` |
| Use SSL | off |
| API Key | *(same key as Sonarr)* |

Do **not** use ports `8989` (Sonarr) or `7878` (Radarr) — those are for real Sonarr/Radarr servers, not Boxarr.

### Option 2 — Full server URL (if your Seerr build has a single URL field)

Some Seerr versions accept one URL per service:

| Service | Server URL | API Key |
|---------|------------|---------|
| Sonarr | `http://boxarr:8080/sonarr` | *(Seerr API key from Boxarr)* |
| Radarr | `http://boxarr:8080/radarr` | *(same key)* |

Hostname must be `boxarr` (Docker DNS on `boxarr-net`), **not** your ZimaOS LAN IP — Seerr runs in the same compose network as Boxarr.

## Required after connecting

For **each** service (Sonarr and Radarr):

1. Click **Test** — should succeed
2. Set **Quality Profile** (dropdown comes from Boxarr)
3. Set **Root Folder** (dropdown comes from Boxarr)
4. Enable **Default Server**
5. Save

Requests fail silently if quality profile or root folder is missing.

## Verify from the host

```bash
KEY="$(sudo sqlite3 /DATA/AppData/boxarr/boxarr.db "SELECT value FROM settings WHERE key='seerr.api_keys' LIMIT 1;")"
docker run --rm --network boxarr-net curlimages/curl:latest -sf \
  "http://boxarr:8080/sonarr/api/v3/system/status?apikey=${KEY}"
docker run --rm --network boxarr-net curlimages/curl:latest -sf \
  "http://boxarr:8080/radarr/api/v3/system/status?apikey=${KEY}"
```

Both should return JSON with a `version` field.

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Test fails / connection refused | Use hostname `boxarr`, port `8080`, not LAN IP |
| Invalid API key | Regenerate in Boxarr → Settings → Requests, or read `seerr.api_keys` from DB |
| Requests stuck after approval | Set default quality profile + root folder on both services |
| Only movies or only TV works | Add **both** Sonarr and Radarr entries |
