# Mobile Setup Guide

`setup.sh` auto-generates `mobile-config.txt` in the repo root with your LAN
IP, every service URL, and every API key. Keep that file handy while you
work through this guide — most apps just need you to paste one URL + one key.

## What's covered

| Use case | App | Platforms |
|---|---|---|
| Watch & play media | **Plex** | iOS, Android, tvOS, web |
| Request movies/TV | **Overseerr** (PWA or app) | iOS, Android, web |
| Manage Radarr + Sonarr | **Ruddarr** | iOS |
| Manage full *arr stack | **nzb360** | Android |
| Cross-platform *arr UI | **LunaSea** | iOS, Android |
| Control qBittorrent | Web UI (or qBitControl) | any / Android |
| Plex analytics | Tautulli web UI | any browser |

---

## 0. Remote access (do this first if you ever use apps outside your house)

All URLs in `mobile-config.txt` are LAN addresses like `http://192.168.4.138:7878`.
On cellular or someone else's Wi-Fi, those won't reach your server. Pick one:

### Tailscale via the Docker stack (recommended — runs as a container, no host install)

`setup.sh` ships an optional `tailscale` service that joins your tailnet and
advertises your LAN. Once enabled, every existing LAN URL in
`mobile-config.txt` works from anywhere — phone reaches `192.168.4.138:7878`
the same on cellular as it does at home.

1. Sign up at https://tailscale.com/ if you haven't (free for personal use).
2. Generate an auth key:
   https://login.tailscale.com/admin/settings/keys → *Generate auth key* →
   Reusable on, Ephemeral off → copy the `tskey-auth-...` string.
3. Paste it into `.env` as `TS_AUTHKEY=tskey-auth-...` and re-run
   `bash scripts/setup.sh <tier>`. The script auto-fills `TS_ROUTES` from
   your LAN IP, starts the `tailscale` container, and prints its tailnet IP.
4. **One-time route approval**: open
   https://login.tailscale.com/admin/machines, find your `mediacenter`
   host, click *Edit route settings*, approve the advertised subnet.
5. Install the Tailscale app on your phone and sign in to the same account.

That's it. Use the same `192.168.4.138:PORT` URLs everywhere this guide
mentions a LAN IP.

#### Native install on the host (alternative)

If you'd rather run Tailscale on the Windows/macOS/Linux host itself
(skipping the container), just install the Tailscale client from
https://tailscale.com/download and use the host's tailnet hostname
(`hostname.tail-xxxxx.ts.net`) in place of `192.168.4.138`. The container
approach is preferred when you want the entire stack — including remote
access — to come up from `docker compose down && setup.sh`.

Other options: Cloudflare Tunnel (free, needs a domain), WireGuard on your
router, or port forwarding + DDNS (not recommended — exposes services to the
public internet).

Plex is special — see the Plex section below. It has its own remote-access
system and doesn't need Tailscale.

---

## 1. Plex (Movies, TV, Music)

Plex handles its own remote access via the `plex.tv` relay, so it works
anywhere out of the box.

1. Install **Plex** from the App Store or Play Store.
2. Sign in with the same plex.tv account the server is claimed to.
3. Your libraries appear automatically.

Optional: **Plexamp** (iOS/Android) for a music-focused client.

---

## 2. Overseerr (request new movies and TV shows)

Overseerr doesn't have native mobile apps, but its web UI is a full PWA —
installing it to the home screen gives you an app-like experience with push
notifications.

### Install as a PWA (iOS + Android)

1. Open `http://<your-server>:5055` in your phone's browser. Sign in with
   your Plex account.
2. **iOS (Safari):** tap Share → *Add to Home Screen*.
   **Android (Chrome):** tap ⋮ → *Install app* / *Add to Home screen*.
3. Done — opens full-screen like a native app.

### Push notifications (optional)

In Overseerr → Settings → Notifications, you can hook up Discord, Telegram,
Pushover, or a self-hosted `ntfy` instance. Easiest:

- **Telegram:** create a bot via `@BotFather`, get the bot token and your
  chat ID, paste into Overseerr. Free, works anywhere.

---

## 3. Ruddarr (iOS — best for Radarr + Sonarr)

1. Install **Ruddarr**: https://apps.apple.com/app/ruddarr/id6476240130
2. Open Ruddarr → *Add Instance*.
3. For **Radarr**:
   - URL: `http://192.168.4.138:7878` (or your tailnet URL)
   - API Key: from `mobile-config.txt` under *Radarr*
   - Tap *Test* — should go green
4. Repeat *Add Instance* for **Sonarr** using its URL and key.
5. Ruddarr's bottom tabs switch between instances. You can browse, search,
   add, monitor, and manually grab releases from here.

Ruddarr doesn't currently support Lidarr — use LunaSea (below) for music.

---

## 4. nzb360 (Android — manages the full stack)

1. Install **nzb360** from Play Store (free version or Pro).
2. Menu → *Server Setup*. Add each service separately:

| Section | URL | API Key |
|---|---|---|
| Sonarr | `http://192.168.4.138:8989` | `SONARR_API_KEY` |
| Radarr | `http://192.168.4.138:7878` | `RADARR_API_KEY` |
| Lidarr | `http://192.168.4.138:8686` | `LIDARR_API_KEY` |
| Prowlarr | `http://192.168.4.138:9696` | `PROWLARR_API_KEY` |
| qBittorrent | `http://192.168.4.138:8085` | username `admin`, password from `mobile-config.txt` |

3. Each service gets its own tab in the drawer. qBittorrent pairs with the
   download-progress view.

---

## 5. LunaSea (iOS + Android — cross-platform)

Good alternative to Ruddarr/nzb360 if you use both iOS and Android, or want
one app for everything.

1. Install **LunaSea**: https://www.lunasea.app/
2. *Settings → Configuration → [Service]*. For each *arr:
   - Host: the service URL from `mobile-config.txt`
   - API Key: from `mobile-config.txt`
3. LunaSea supports Radarr, Sonarr, Lidarr, Tautulli, Overseerr, and
   qBittorrent natively. Swipe between modules from the home screen.

---

## 6. qBittorrent (downloads)

Easiest: open `http://192.168.4.138:8085` in your phone's browser. The qBit
Web UI is responsive and works fine on mobile. Login: `admin` /
`mediaCenter!2026` (or whatever you set `QB_PASSWORD` to).

For a native app feel:
- **Android:** *qBitController* or *qBit Controller* (both free on Play
  Store). Paste the URL + credentials.
- **iOS:** *qBit Remote* or use Safari + *Add to Home Screen* on the Web UI.

Note: qBittorrent sits behind gluetun, so the Web UI only responds over your
LAN (or tailnet if you chose Tailscale above).

---

## 7. Tautulli (Plex watch history / analytics)

No maintained native apps. Use the Web UI:

1. Open `http://192.168.4.138:8181` in mobile browser.
2. Add to Home Screen for app-like launching.

For quick glances, Tautulli can push notifications to the same services as
Overseerr (Telegram, Discord, ntfy, etc.).

---

## Troubleshooting

- **"Can't connect" from an app** — you're probably on cellular and the app
  has a LAN URL. See §0 (Tailscale), or reconnect to home Wi-Fi.
- **HTTP 401 / auth error** — API key mismatch. Re-open `mobile-config.txt`
  and copy exactly (no surrounding whitespace).
- **API keys changed after I re-ran setup.sh** — `setup.sh` re-extracts keys
  from each container's `config.xml` on every run. If you rebuilt a
  container's appdata, the key rotated and every mobile app needs the new
  one. Always trust the current `mobile-config.txt`.
- **Ruddarr/nzb360 shows "connection refused" on cellular but fine on
  Wi-Fi** — same as the first bullet. LAN IP only routes on the LAN.
- **Overseerr can't find my Plex server** — check `PLEX_URL` in `.env` uses
  your LAN IP (not `localhost` — containers can't reach the host via
  localhost). `setup.sh`'s `detect_plex` now handles this automatically.

---

## Quick reference

`mobile-config.txt` (auto-generated in repo root) is the source of truth for
URLs and keys on your install. If you change `APPDATA_PATH` or rebuild a
container's config, re-run `bash scripts/setup.sh <tier>` and the file
regenerates with fresh values.
