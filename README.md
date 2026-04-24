# Media Center

Docker-compose stack for a self-hosted media center. Designed for easy teardown and rebuild — all config lives in `APPDATA_PATH`, all media in `DATA_PATH`. Plex runs on the host for GPU transcoding; everything else is containerized.

## Quick Start

```bash
# 1. Run setup — it auto-detects your system, creates everything, and wires all services together
./scripts/setup.sh minimal    # Movies & TV only
./scripts/setup.sh standard   # + Music, Subtitles, Monitoring
./scripts/setup.sh full       # Everything
```

On first run, setup.sh will:
- Create `.env` with auto-detected PUID/PGID, timezone, and paths
- **You only need to edit `.env` once** to add your VPN credentials, then re-run
- Create all data/appdata directories
- Pre-configure qBittorrent (save paths, categories, auth)
- Start all containers and wait for health checks
- Extract API keys from each service
- Wire Radarr, Sonarr, Lidarr, Readarr with root folders and download clients
- Connect Prowlarr to all *arr apps and FlareSolverr
- Verify VPN is working
- Print a summary with all URLs

**The only manual step:** open Prowlarr and add your indexers (tracker-specific credentials).

## Tiers

| Tier | Services | Use Case |
|------|----------|----------|
| **minimal** | Radarr, Sonarr | Just movies and TV shows |
| **standard** | + Bazarr, Lidarr, Overseerr, Tautulli | Add subtitles, music, Plex monitoring, media requests |
| **full** | + Readarr, Audiobookshelf, Calibre-Web, Mylar3, Recyclarr, Unpackerr, Homarr | Books, audiobooks, comics, TRaSH Guides automation, dashboard |

Infrastructure always runs: **Gluetun** (VPN), **qBittorrent**, **Prowlarr** (indexers), **FlareSolverr** (Cloudflare bypass).

## Service Ports

| Service | Port | Tier |
|---------|------|------|
| qBittorrent | 8085 | infra |
| Prowlarr | 9696 | infra |
| FlareSolverr | 8191 | infra |
| Radarr | 7878 | minimal |
| Sonarr | 8989 | minimal |
| Bazarr | 6767 | standard |
| Lidarr | 8686 | standard |
| Overseerr | 5055 | standard |
| Tautulli | 8181 | standard |
| Readarr | 8787 | full |
| Audiobookshelf | 13378 | full |
| Calibre-Web | 8083 | full |
| Mylar3 | 8090 | full |
| Homarr | 7575 | full |

## VPN Setup

Supports **ExpressVPN** and **NordVPN** via [Gluetun](https://github.com/qdm12/gluetun). Set in `.env`:

```env
# NordVPN with OpenVPN
VPN_SERVICE_PROVIDER=nordvpn
VPN_TYPE=openvpn
OPENVPN_USER=your-service-username
OPENVPN_PASSWORD=your-service-password

# NordVPN with WireGuard
VPN_SERVICE_PROVIDER=nordvpn
VPN_TYPE=wireguard
WIREGUARD_PRIVATE_KEY=your-key
SERVER_COUNTRIES=United States

# ExpressVPN
VPN_SERVICE_PROVIDER=expressvpn
EXPRESSVPN_ACTIVATION_CODE=your-code
```

Only torrent traffic goes through the VPN. All other services are on your local network.

## Directory Structure

Uses the [TRaSH Guides](https://trash-guides.info/File-and-Folder-Structure/How-to-set-up/Docker/) recommended structure for hardlinks and atomic moves:

```
$DATA_PATH/
├── torrents/
│   ├── movies/
│   ├── tv/
│   ├── music/
│   └── books/
└── media/
    ├── movies/      <- Plex library
    ├── tv/          <- Plex library
    ├── music/
    ├── audiobooks/
    ├── comics/
    └── ebooks/
```

## After Setup

Everything is auto-configured by `setup.sh`. The only remaining step:

1. **Prowlarr** (`:9696`) — Add your torrent indexers. They auto-sync to all *arr apps.

## Managing the Stack

```bash
# Start with a specific tier
docker compose --profile standard up -d

# Stop everything
docker compose --profile full down

# Update all containers
docker compose --profile full pull && docker compose --profile full up -d

# View logs
docker compose logs -f radarr
```

## Notes

- **Plex** runs on the host (not in Docker) for GPU access. Point it at `$DATA_PATH/media/`.
- **Readarr** project was archived June 2025 — existing installs work, no future updates. Audiobookshelf + Calibre-Web cover the gap.
- **Prowlarr** replaces Jackett as the modern indexer manager with native *arr integration.
- **Recyclarr** auto-syncs TRaSH Guides quality profiles — edit `recyclarr.yml` and add your API keys after first run.
