# Notes for Claude

## Pending cross-platform validation

`scripts/setup.sh` was hardened for cross-platform use in PR #1 but only
verified end-to-end on **Windows 11 + Git Bash + Docker Desktop (WSL2)**.
Two code paths remain untested on other OSes — if you're invoked in this
repo on macOS or Linux, please exercise and confirm them, then delete this
section from `CLAUDE.md`.

### What to verify

1. **`detect_plex` — Plex token extraction from `Preferences.xml`**
   - macOS path: `~/Library/Application Support/Plex Media Server/Preferences.xml`
   - Linux paths (first that exists wins):
     - `~/.config/Plex Media Server/Preferences.xml`
     - `/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml`
   - With Plex running on the host, run `bash scripts/setup.sh standard` and
     confirm `.env` receives a non-empty `PLEX_TOKEN` and Overseerr auto-wires
     on first run.

2. **`detect_lan_ip` — platform branches**
   - macOS: `ipconfig getifaddr en0` / `en1`
   - Linux: `hostname -I | awk '{print $1}'`
   - Confirm `mobile-config.txt`'s `Server IP:` line is the actual LAN IP
     (not `YOUR_SERVER_IP` and not localhost).

3. **No-Plex fallback** (on any platform)
   - Stop Plex, run `bash scripts/setup.sh standard`, confirm `detect_plex`
     logs "No Plex on localhost:32400 — leaving PLEX_URL/PLEX_TOKEN as-is"
     and the script continues cleanly through Overseerr's manual fallback.

### How to clear this note

Once validated, delete this entire "Pending cross-platform validation"
section in the same commit as any follow-up fixes.
