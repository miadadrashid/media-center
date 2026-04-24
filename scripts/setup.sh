#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Media Center — Fully Automated Setup
# Usage: ./scripts/setup.sh [minimal|standard|full]
# ==============================================================================

TIER="${1:-minimal}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE="docker compose --project-directory $PROJECT_DIR"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ==============================================================================
# Phase 1: Preflight
# ==============================================================================
preflight() {
  if [[ "$TIER" != "minimal" && "$TIER" != "standard" && "$TIER" != "full" && "$TIER" != "push-env" && "$TIER" != "pull-env" ]]; then
    echo "Usage: $0 [minimal|standard|full|push-env|pull-env]"
    echo ""
    echo "  minimal   — Movies & TV (Radarr, Sonarr)"
    echo "  standard  — + Subtitles, Music, Monitoring, Requests"
    echo "  full      — + Books, Audiobooks, Comics, Automation, Dashboard"
    echo ""
    echo "  push-env  — Save .env to a private GitHub Gist"
    echo "  pull-env  — Restore .env from GitHub Gist"
    exit 1
  fi

  if ! command -v docker &>/dev/null; then
    err "docker is not installed. Install it first: https://docs.docker.com/engine/install/"
    exit 1
  fi

  if ! docker compose version &>/dev/null; then
    err "docker compose plugin is not installed."
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    err "curl is required but not installed."
    exit 1
  fi

  ok "Prerequisites: docker, docker compose, curl"
}

# ==============================================================================
# Phase 2: Environment
# ==============================================================================
setup_env() {
  local detected_puid detected_pgid detected_tz

  detected_puid="$(id -u)"
  detected_pgid="$(id -g)"

  # Detect timezone
  if [[ -f /etc/timezone ]]; then
    detected_tz="$(cat /etc/timezone)"
  elif [[ -L /etc/localtime ]]; then
    detected_tz="$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')"
  elif command -v timedatectl &>/dev/null; then
    detected_tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'America/New_York')"
  else
    detected_tz="America/New_York"
  fi

  local default_data="$HOME/media-center-data/data"
  local default_appdata="$HOME/media-center-data/appdata"

  if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    info "Creating .env from template with auto-detected values..."
    sed \
      -e "s|__PUID__|$detected_puid|g" \
      -e "s|__PGID__|$detected_pgid|g" \
      -e "s|__TZ__|$detected_tz|g" \
      -e "s|__DATA_PATH__|$default_data|g" \
      -e "s|__APPDATA_PATH__|$default_appdata|g" \
      "$PROJECT_DIR/.env.example" > "$PROJECT_DIR/.env"
    ok "Created .env (PUID=$detected_puid, PGID=$detected_pgid, TZ=$detected_tz)"
  else
    ok "Using existing .env"
  fi

  # Source .env
  set -a
  source "$PROJECT_DIR/.env"
  set +a

  # Validate VPN credentials
  if [[ -z "${OPENVPN_USER:-}" && -z "${WIREGUARD_PRIVATE_KEY:-}" && -z "${EXPRESSVPN_ACTIVATION_CODE:-}" ]]; then
    warn "No VPN credentials in .env — gluetun will fail to connect."
    warn "Edit $PROJECT_DIR/.env, add VPN credentials, and re-run."
    exit 1
  fi

  # Detect Plex on host and update .env idempotently
  detect_plex
}

# ==============================================================================
# Phase 3: Directories
# ==============================================================================
create_dirs() {
  info "Creating directories..."

  # Data dirs — always
  mkdir -p "$DATA_PATH"/torrents/{movies,tv}
  mkdir -p "$DATA_PATH"/media/{movies,tv}

  # Appdata — infrastructure + minimal
  mkdir -p "$APPDATA_PATH"/{gluetun,qbittorrent,prowlarr,radarr,sonarr}

  # Standard
  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    mkdir -p "$DATA_PATH"/torrents/music
    mkdir -p "$DATA_PATH"/media/music
    mkdir -p "$APPDATA_PATH"/{bazarr,lidarr,overseerr,tautulli}
  fi

  # Full
  if [[ "$TIER" == "full" ]]; then
    mkdir -p "$DATA_PATH"/torrents/books
    mkdir -p "$DATA_PATH"/media/{audiobooks,comics,ebooks}
    mkdir -p "$APPDATA_PATH"/{readarr,mylar3,calibre-web,recyclarr}
    mkdir -p "$APPDATA_PATH"/audiobookshelf/{config,metadata}
    mkdir -p "$APPDATA_PATH"/homarr/{configs,icons}
  fi

  ok "Directories created"
}

# ==============================================================================
# Phase 4: Pre-configure qBittorrent
# ==============================================================================
preconfigure_qbittorrent() {
  local qb_conf_dir="$APPDATA_PATH/qbittorrent/qBittorrent"
  local qb_conf="$qb_conf_dir/qBittorrent.conf"

  if [[ -f "$qb_conf" ]]; then
    ok "qBittorrent config already exists, skipping pre-configuration"
    return
  fi

  info "Pre-configuring qBittorrent..."
  mkdir -p "$qb_conf_dir"

  local categories="movies,tv"
  [[ "$TIER" == "standard" || "$TIER" == "full" ]] && categories="movies,tv,music"
  [[ "$TIER" == "full" ]] && categories="movies,tv,music,books"

  cat > "$qb_conf" << 'QBCONF'
[AutoRun]
enabled=false
program=

[BitTorrent]
Session\AddTorrentStopped=false
Session\DefaultSavePath=/data/torrents/
Session\Port=6881
Session\QueueingSystemEnabled=true
Session\ShareLimitAction=Stop
Session\TempPath=/data/torrents/incomplete/

[LegalNotice]
Accepted=true

[Meta]
MigrationVersion=8

[Network]
PortForwardingEnabled=false
Proxy\HostnameLookupEnabled=false
Proxy\Profiles\BitTorrent=true
Proxy\Profiles\Misc=true
Proxy\Profiles\RSS=true

[Preferences]
Connection\PortRangeMin=6881
Connection\UPnP=false
Downloads\SavePath=/data/torrents/
Downloads\TempPath=/data/torrents/incomplete/
WebUI\Address=*
WebUI\AuthSubnetWhitelist=0.0.0.0/0
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\LocalHostAuth=false
WebUI\ServerDomains=*
WebUI\Port=8080
QBCONF

  ok "qBittorrent pre-configured (save path: /data/torrents/, auth whitelist enabled)"
}

# ==============================================================================
# Phase 5: Start Containers
# ==============================================================================
wait_for_healthy() {
  local container="$1" max_wait="${2:-90}" elapsed=0
  info "Waiting for $container to be healthy..."
  while [[ $elapsed -lt $max_wait ]]; do
    local status
    status="$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")"
    if [[ "$status" == "healthy" ]]; then
      ok "$container is healthy"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  warn "$container did not become healthy within ${max_wait}s (status: $status)"
  return 1
}

wait_for_http() {
  local name="$1" url="$2" max_wait="${3:-60}" elapsed=0
  info "Waiting for $name to respond..."
  while [[ $elapsed -lt $max_wait ]]; do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
    # Accept 2xx, 3xx, and 401 (auth required = service is up)
    if [[ "$code" =~ ^[234] ]]; then
      ok "$name is up (HTTP $code)"
      return 0
    fi
    sleep 2
    elapsed=$((elapsed + 2))
  done
  warn "$name did not respond within ${max_wait}s"
  return 1
}

start_containers() {
  info "Starting containers (tier: $TIER)..."
  cd "$PROJECT_DIR"
  $COMPOSE --profile "$TIER" up -d

  # Wait for gluetun VPN
  if ! wait_for_healthy gluetun 90; then
    warn "Gluetun VPN not healthy — check your VPN credentials in .env"
    warn "Continuing setup (services will work once VPN connects)..."
  fi

  # Wait for core services
  wait_for_http "Prowlarr"  "http://localhost:9696" 60
  wait_for_http "Radarr"    "http://localhost:7878" 60
  wait_for_http "Sonarr"    "http://localhost:8989" 60
  wait_for_http "qBittorrent" "http://localhost:8085" 60 || true

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    wait_for_http "Bazarr"    "http://localhost:6767" 60 || true
    wait_for_http "Lidarr"    "http://localhost:8686" 60 || true
    wait_for_http "Overseerr" "http://localhost:5055" 60 || true
    wait_for_http "Tautulli"  "http://localhost:8181" 60 || true
  fi

  if [[ "$TIER" == "full" ]]; then
    wait_for_http "Readarr"        "http://localhost:8787" 60 || true
    wait_for_http "Audiobookshelf" "http://localhost:13378" 60 || true
    wait_for_http "Calibre-Web"    "http://localhost:8083" 60 || true
    wait_for_http "Mylar3"         "http://localhost:8090" 60 || true
  fi
}

# ==============================================================================
# Phase 6: Extract API Keys
# ==============================================================================
extract_key_from_xml() {
  local file="$1"
  # macOS-compatible (no grep -P)
  sed -n 's/.*<ApiKey>\([^<]*\)<\/ApiKey>.*/\1/p' "$file" 2>/dev/null || echo ""
}

extract_api_keys() {
  info "Extracting API keys from service configs..."

  # Wait a moment for config files to be written
  local attempts=0
  while [[ ! -f "$APPDATA_PATH/radarr/config.xml" && $attempts -lt 15 ]]; do
    sleep 2
    attempts=$((attempts + 1))
  done

  RADARR_API_KEY="$(extract_key_from_xml "$APPDATA_PATH/radarr/config.xml")"
  SONARR_API_KEY="$(extract_key_from_xml "$APPDATA_PATH/sonarr/config.xml")"
  PROWLARR_API_KEY="$(extract_key_from_xml "$APPDATA_PATH/prowlarr/config.xml")"

  if [[ -z "$RADARR_API_KEY" || -z "$SONARR_API_KEY" || -z "$PROWLARR_API_KEY" ]]; then
    err "Failed to extract one or more API keys. Check container logs."
    return 1
  fi

  ok "Radarr API key:   ${RADARR_API_KEY:0:8}..."
  ok "Sonarr API key:   ${SONARR_API_KEY:0:8}..."
  ok "Prowlarr API key: ${PROWLARR_API_KEY:0:8}..."

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    LIDARR_API_KEY="$(extract_key_from_xml "$APPDATA_PATH/lidarr/config.xml")"
    if [[ -n "$LIDARR_API_KEY" ]]; then
      ok "Lidarr API key:   ${LIDARR_API_KEY:0:8}..."
    fi
  fi

  if [[ "$TIER" == "full" ]]; then
    READARR_API_KEY="$(extract_key_from_xml "$APPDATA_PATH/readarr/config.xml")"
    if [[ -n "$READARR_API_KEY" ]]; then
      ok "Readarr API key:  ${READARR_API_KEY:0:8}..."
    fi
  fi

  # Update .env with discovered keys
  info "Saving API keys to .env..."
  sed -i.bak \
    -e "s|^RADARR_API_KEY=.*|RADARR_API_KEY=$RADARR_API_KEY|" \
    -e "s|^SONARR_API_KEY=.*|SONARR_API_KEY=$SONARR_API_KEY|" \
    -e "s|^PROWLARR_API_KEY=.*|PROWLARR_API_KEY=$PROWLARR_API_KEY|" \
    "$PROJECT_DIR/.env"

  if [[ -n "${LIDARR_API_KEY:-}" ]]; then
    sed -i.bak "s|^LIDARR_API_KEY=.*|LIDARR_API_KEY=$LIDARR_API_KEY|" "$PROJECT_DIR/.env"
  fi
  if [[ -n "${READARR_API_KEY:-}" ]]; then
    sed -i.bak "s|^READARR_API_KEY=.*|READARR_API_KEY=$READARR_API_KEY|" "$PROJECT_DIR/.env"
  fi

  rm -f "$PROJECT_DIR/.env.bak"
  ok "API keys saved to .env"
}

# ==============================================================================
# Phase 7: Wire Services
# ==============================================================================
api_post() {
  local url="$1" api_key="$2" data="$3"
  curl -sf -o /dev/null \
    -H "X-Api-Key: $api_key" \
    -H "Content-Type: application/json" \
    -d "$data" "$url" 2>/dev/null
  return $?
}

api_get() {
  local url="$1" api_key="$2"
  curl -sf -H "X-Api-Key: $api_key" "$url" 2>/dev/null || echo "[]"
}

add_indexer() {
  local name="$1" def_file="$2" base_url="$3" tag_id="$4"
  local tags_json="[]"
  [[ -n "$tag_id" ]] && tags_json="[$tag_id]"

  local result
  result="$(curl -sf \
    -H "X-Api-Key: $PROWLARR_API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":\"$name\",
      \"implementation\":\"Cardigann\",
      \"configContract\":\"CardigannSettings\",
      \"protocol\":\"torrent\",
      \"priority\":25,
      \"enable\":true,
      \"appProfileId\":1,
      \"tags\":$tags_json,
      \"fields\":[
        {\"name\":\"definitionFile\",\"value\":\"$def_file\"},
        {\"name\":\"baseUrl\",\"value\":\"$base_url\"},
        {\"name\":\"baseSettings.limitsUnit\",\"value\":0},
        {\"name\":\"torrentBaseSettings.preferMagnetUrl\",\"value\":true}
      ]
    }" "http://localhost:9696/api/v1/indexer" 2>/dev/null || echo "")"

  if echo "$result" | grep -q '"id"'; then
    ok "Indexer added: $name"
  else
    warn "Indexer $name may already exist or failed to add"
  fi
}

configure_radarr() {
  info "Configuring Radarr..."

  # Check if already configured
  local existing
  existing="$(api_get "http://localhost:7878/api/v3/rootfolder" "$RADARR_API_KEY")"
  if echo "$existing" | grep -q "/data/media/movies"; then
    ok "Radarr already configured, skipping"
    return
  fi

  # Add root folder
  api_post "http://localhost:7878/api/v3/rootfolder" "$RADARR_API_KEY" \
    '{"path":"/data/media/movies"}'
  ok "Radarr root folder: /data/media/movies"

  # Add qBittorrent download client
  api_post "http://localhost:7878/api/v3/downloadclient" "$RADARR_API_KEY" \
    '{
      "enable":true, "protocol":"torrent", "priority":1,
      "name":"qBittorrent", "implementation":"QBittorrent",
      "configContract":"QBittorrentSettings",
      "fields":[
        {"name":"host","value":"gluetun"},
        {"name":"port","value":8080},
        {"name":"username","value":"admin"},
        {"name":"password","value":""},
        {"name":"movieCategory","value":"movies"},
        {"name":"initialState","value":0},
        {"name":"sequentialOrder","value":false},
        {"name":"firstAndLastFirst","value":false}
      ]
    }'
  ok "Radarr download client: qBittorrent via gluetun"
}

configure_sonarr() {
  info "Configuring Sonarr..."

  local existing
  existing="$(api_get "http://localhost:8989/api/v3/rootfolder" "$SONARR_API_KEY")"
  if echo "$existing" | grep -q "/data/media/tv"; then
    ok "Sonarr already configured, skipping"
    return
  fi

  api_post "http://localhost:8989/api/v3/rootfolder" "$SONARR_API_KEY" \
    '{"path":"/data/media/tv"}'
  ok "Sonarr root folder: /data/media/tv"

  api_post "http://localhost:8989/api/v3/downloadclient" "$SONARR_API_KEY" \
    '{
      "enable":true, "protocol":"torrent", "priority":1,
      "name":"qBittorrent", "implementation":"QBittorrent",
      "configContract":"QBittorrentSettings",
      "fields":[
        {"name":"host","value":"gluetun"},
        {"name":"port","value":8080},
        {"name":"username","value":"admin"},
        {"name":"password","value":""},
        {"name":"tvCategory","value":"tv"},
        {"name":"initialState","value":0},
        {"name":"sequentialOrder","value":false},
        {"name":"firstAndLastFirst","value":false}
      ]
    }'
  ok "Sonarr download client: qBittorrent via gluetun"
}

configure_lidarr() {
  info "Configuring Lidarr..."

  local existing
  existing="$(api_get "http://localhost:8686/api/v1/rootfolder" "$LIDARR_API_KEY")"
  if echo "$existing" | grep -q "/data/media/music"; then
    ok "Lidarr already configured, skipping"
    return
  fi

  # Lidarr's rootfolder POST requires defaultQualityProfileId + defaultMetadataProfileId
  # (Radarr/Sonarr don't). Fetch the first of each from the live config.
  local lidarr_qp lidarr_mp
  lidarr_qp="$(api_get "http://localhost:8686/api/v1/qualityprofile"  "$LIDARR_API_KEY" \
              | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
  lidarr_mp="$(api_get "http://localhost:8686/api/v1/metadataprofile" "$LIDARR_API_KEY" \
              | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
  lidarr_qp="${lidarr_qp:-1}"; lidarr_mp="${lidarr_mp:-1}"

  api_post "http://localhost:8686/api/v1/rootfolder" "$LIDARR_API_KEY" \
    "{\"path\":\"/data/media/music\",\"name\":\"Music\",\"defaultQualityProfileId\":$lidarr_qp,\"defaultMetadataProfileId\":$lidarr_mp,\"defaultMonitorOption\":\"all\",\"defaultNewItemMonitorOption\":\"all\",\"defaultTags\":[]}"
  ok "Lidarr root folder: /data/media/music"

  api_post "http://localhost:8686/api/v1/downloadclient" "$LIDARR_API_KEY" \
    '{
      "enable":true, "protocol":"torrent", "priority":1,
      "name":"qBittorrent", "implementation":"QBittorrent",
      "configContract":"QBittorrentSettings",
      "fields":[
        {"name":"host","value":"gluetun"},
        {"name":"port","value":8080},
        {"name":"username","value":"admin"},
        {"name":"password","value":""},
        {"name":"musicCategory","value":"music"},
        {"name":"initialState","value":0},
        {"name":"sequentialOrder","value":false},
        {"name":"firstAndLastFirst","value":false}
      ]
    }'
  ok "Lidarr download client: qBittorrent via gluetun"
}

configure_readarr() {
  info "Configuring Readarr..."

  local existing
  existing="$(api_get "http://localhost:8787/api/v1/rootfolder" "$READARR_API_KEY")"
  if echo "$existing" | grep -q "/data/media/ebooks"; then
    ok "Readarr already configured, skipping"
    return
  fi

  api_post "http://localhost:8787/api/v1/rootfolder" "$READARR_API_KEY" \
    '{"path":"/data/media/ebooks","name":"eBooks"}'
  ok "Readarr root folder: /data/media/ebooks"

  api_post "http://localhost:8787/api/v1/downloadclient" "$READARR_API_KEY" \
    '{
      "enable":true, "protocol":"torrent", "priority":1,
      "name":"qBittorrent", "implementation":"QBittorrent",
      "configContract":"QBittorrentSettings",
      "fields":[
        {"name":"host","value":"gluetun"},
        {"name":"port","value":8080},
        {"name":"username","value":"admin"},
        {"name":"password","value":""},
        {"name":"bookCategory","value":"books"},
        {"name":"initialState","value":0},
        {"name":"sequentialOrder","value":false},
        {"name":"firstAndLastFirst","value":false}
      ]
    }'
  ok "Readarr download client: qBittorrent via gluetun"
}

configure_prowlarr() {
  info "Configuring Prowlarr..."

  # Check if already has apps configured
  local existing_apps existing_proxies
  existing_apps="$(api_get "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY")"
  existing_proxies="$(api_get "http://localhost:9696/api/v1/indexerProxy" "$PROWLARR_API_KEY")"
  if echo "$existing_apps" | grep -q "Radarr" && echo "$existing_proxies" | grep -q "FlareSolverr"; then
    ok "Prowlarr already configured, skipping"
    return
  fi

  # Add Radarr
  api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY" \
    "{
      \"name\":\"Radarr\", \"syncLevel\":\"fullSync\",
      \"implementation\":\"Radarr\", \"configContract\":\"RadarrSettings\",
      \"fields\":[
        {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},
        {\"name\":\"baseUrl\",\"value\":\"http://radarr:7878\"},
        {\"name\":\"apiKey\",\"value\":\"$RADARR_API_KEY\"},
        {\"name\":\"syncCategories\",\"value\":[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]}
      ]
    }"
  ok "Prowlarr -> Radarr (fullSync)"

  # Add Sonarr
  api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY" \
    "{
      \"name\":\"Sonarr\", \"syncLevel\":\"fullSync\",
      \"implementation\":\"Sonarr\", \"configContract\":\"SonarrSettings\",
      \"fields\":[
        {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},
        {\"name\":\"baseUrl\",\"value\":\"http://sonarr:8989\"},
        {\"name\":\"apiKey\",\"value\":\"$SONARR_API_KEY\"},
        {\"name\":\"syncCategories\",\"value\":[5000,5010,5020,5030,5040,5045,5050,5060,5070,5080]}
      ]
    }"
  ok "Prowlarr -> Sonarr (fullSync)"

  # Add Lidarr (standard+)
  if [[ "$TIER" == "standard" || "$TIER" == "full" ]] && [[ -n "${LIDARR_API_KEY:-}" ]]; then
    api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY" \
      "{
        \"name\":\"Lidarr\", \"syncLevel\":\"fullSync\",
        \"implementation\":\"Lidarr\", \"configContract\":\"LidarrSettings\",
        \"fields\":[
          {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},
          {\"name\":\"baseUrl\",\"value\":\"http://lidarr:8686\"},
          {\"name\":\"apiKey\",\"value\":\"$LIDARR_API_KEY\"},
          {\"name\":\"syncCategories\",\"value\":[3000,3010,3020,3030,3040]}
        ]
      }"
    ok "Prowlarr -> Lidarr (fullSync)"
  fi

  # Add Readarr (full)
  if [[ "$TIER" == "full" ]] && [[ -n "${READARR_API_KEY:-}" ]]; then
    api_post "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY" \
      "{
        \"name\":\"Readarr\", \"syncLevel\":\"fullSync\",
        \"implementation\":\"Readarr\", \"configContract\":\"ReadarrSettings\",
        \"fields\":[
          {\"name\":\"prowlarrUrl\",\"value\":\"http://prowlarr:9696\"},
          {\"name\":\"baseUrl\",\"value\":\"http://readarr:8787\"},
          {\"name\":\"apiKey\",\"value\":\"$READARR_API_KEY\"},
          {\"name\":\"syncCategories\",\"value\":[7000,7010,7020,7030,7040,7050,7060]}
        ]
      }"
    ok "Prowlarr -> Readarr (fullSync)"
  fi

  # Create "flaresolverr" tag for linking proxy to indexers
  local tag_response
  tag_response="$(curl -sf -H "X-Api-Key: $PROWLARR_API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"label":"flaresolverr"}' \
    "http://localhost:9696/api/v1/tag" 2>/dev/null || echo "{}")"
  local fs_tag_id
  fs_tag_id="$(echo "$tag_response" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')"
  fs_tag_id="${fs_tag_id:-1}"

  # Add FlareSolverr proxy with the tag
  api_post "http://localhost:9696/api/v1/indexerProxy" "$PROWLARR_API_KEY" \
    "{
      \"name\":\"FlareSolverr\", \"implementation\":\"FlareSolverr\",
      \"configContract\":\"FlareSolverrSettings\",
      \"fields\":[
        {\"name\":\"host\",\"value\":\"http://flaresolverr:8191\"},
        {\"name\":\"requestTimeout\",\"value\":60}
      ],
      \"tags\":[$fs_tag_id]
    }"
  ok "Prowlarr -> FlareSolverr proxy (tag: flaresolverr)"

  # Add common Cloudflare-protected indexers with the flaresolverr tag
  info "Adding public indexers..."
  add_indexer "1337x" "1337x" "https://1337x.to/" "$fs_tag_id"
  add_indexer "The Pirate Bay" "thepiratebay" "https://thepiratebay.org/" ""
}

configure_overseerr() {
  info "Configuring Overseerr..."

  if [[ -z "${PLEX_TOKEN:-}" ]]; then
    warn "PLEX_TOKEN not set in .env — skipping Overseerr auto-setup"
    warn "Set PLEX_TOKEN and re-run, or configure Overseerr manually at http://localhost:5055"
    return
  fi

  # Check if already configured
  local existing
  existing="$(curl -sf http://localhost:5055/api/v1/settings/radarr 2>/dev/null || echo "[]")"
  if echo "$existing" | grep -q '"hostname"'; then
    ok "Overseerr already configured, skipping"
    return
  fi

  # 1. Authenticate with Plex token — get session cookie
  local cookie_file="/tmp/overseerr_cookies_$$"
  curl -sf -c "$cookie_file" -X POST http://localhost:5055/api/v1/auth/plex \
    -H "Content-Type: application/json" \
    -d "{\"authToken\":\"$PLEX_TOKEN\"}" >/dev/null 2>&1
  local os_cookie
  os_cookie="$(grep connect.sid "$cookie_file" 2>/dev/null | awk '{print $NF}')"

  if [[ -z "$os_cookie" ]]; then
    warn "Overseerr Plex auth failed — check PLEX_TOKEN"
    rm -f "$cookie_file"
    return
  fi
  ok "Overseerr Plex auth successful"

  # 2. Get Radarr quality profile (first one)
  local radarr_profiles
  radarr_profiles="$(api_get "http://localhost:7878/api/v3/qualityprofile" "$RADARR_API_KEY")"
  local radarr_profile_id radarr_profile_name
  radarr_profile_id="$(echo "$radarr_profiles" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
  radarr_profile_name="$(echo "$radarr_profiles" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
  radarr_profile_id="${radarr_profile_id:-1}"
  radarr_profile_name="${radarr_profile_name:-Any}"

  # 3. Get Sonarr quality profile (first one)
  local sonarr_profiles
  sonarr_profiles="$(api_get "http://localhost:8989/api/v3/qualityprofile" "$SONARR_API_KEY")"
  local sonarr_profile_id sonarr_profile_name
  sonarr_profile_id="$(echo "$sonarr_profiles" | sed -n 's/.*"id":\([0-9]*\).*/\1/p' | head -1)"
  sonarr_profile_name="$(echo "$sonarr_profiles" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
  sonarr_profile_id="${sonarr_profile_id:-1}"
  sonarr_profile_name="${sonarr_profile_name:-Any}"

  # 4. Add Radarr to Overseerr
  curl -sf -o /dev/null -b "connect.sid=$os_cookie" \
    -X POST http://localhost:5055/api/v1/settings/radarr \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":\"Radarr\",
      \"hostname\":\"radarr\",
      \"port\":7878,
      \"apiKey\":\"$RADARR_API_KEY\",
      \"useSsl\":false,
      \"activeProfileId\":$radarr_profile_id,
      \"activeProfileName\":\"$radarr_profile_name\",
      \"activeDirectory\":\"/data/media/movies\",
      \"is4k\":false,
      \"minimumAvailability\":\"released\",
      \"isDefault\":true
    }" 2>/dev/null || true
  ok "Overseerr -> Radarr (profile: $radarr_profile_name)"

  # 5. Add Sonarr to Overseerr
  curl -sf -o /dev/null -b "connect.sid=$os_cookie" \
    -X POST http://localhost:5055/api/v1/settings/sonarr \
    -H "Content-Type: application/json" \
    -d "{
      \"name\":\"Sonarr\",
      \"hostname\":\"sonarr\",
      \"port\":8989,
      \"apiKey\":\"$SONARR_API_KEY\",
      \"useSsl\":false,
      \"activeProfileId\":$sonarr_profile_id,
      \"activeProfileName\":\"$sonarr_profile_name\",
      \"activeDirectory\":\"/data/media/tv\",
      \"is4k\":false,
      \"enableSeasonFolders\":true,
      \"isDefault\":true
    }" 2>/dev/null || true
  ok "Overseerr -> Sonarr (profile: $sonarr_profile_name)"

  # 6. Initialize Overseerr (mark setup complete)
  curl -sf -o /dev/null -b "connect.sid=$os_cookie" \
    -X POST http://localhost:5055/api/v1/settings/initialize \
    -H "Content-Type: application/json" 2>/dev/null || true
  ok "Overseerr setup initialized"

  rm -f "$cookie_file"
}

detect_lan_ip() {
  local ip=""
  case "$(uname -s)" in
    Darwin)
      ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
      ;;
    Linux)
      ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Git Bash / Cygwin on Windows. Windows `ipconfig` outputs UTF-16 and isn't
      # `ipconfig getifaddr`-compatible, so call PowerShell for a clean IPv4.
      ip="$(powershell.exe -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred | Where-Object { \$_.InterfaceAlias -notmatch 'Loopback|vEthernet|WSL|Docker' -and \$_.IPAddress -notmatch '^(169\.254|127\.)' } | Sort-Object InterfaceMetric | Select-Object -First 1).IPAddress" 2>/dev/null | tr -d '\r\n')"
      ;;
  esac
  echo "$ip"
}

detect_plex() {
  # Idempotent: probe localhost:32400 for a running Plex Media Server. If found,
  # update PLEX_URL to use the LAN IP (so containers can reach it) and pull the
  # auth token from the host's Preferences.xml. Always overwrites detected values
  # (matching extract_api_keys' behavior). Silently skips if Plex isn't on the host.
  if ! curl -sf --max-time 3 http://localhost:32400/identity >/dev/null 2>&1; then
    info "No Plex on localhost:32400 — leaving PLEX_URL/PLEX_TOKEN as-is"
    return
  fi

  local lan_ip prefs="" plex_url plex_token=""
  lan_ip="$(detect_lan_ip)"
  plex_url="http://${lan_ip:-host.docker.internal}:32400"

  # Windows stores PlexOnlineToken in the registry; macOS/Linux use Preferences.xml.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      plex_token="$(powershell.exe -NoProfile -Command "(Get-ItemProperty 'HKCU:\\Software\\Plex, Inc.\\Plex Media Server' -Name PlexOnlineToken -ErrorAction SilentlyContinue).PlexOnlineToken" 2>/dev/null | tr -d '\r\n')"
      ;;
    Darwin)
      prefs="$HOME/Library/Application Support/Plex Media Server/Preferences.xml"
      ;;
    Linux)
      for p in \
          "$HOME/.config/Plex Media Server/Preferences.xml" \
          "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml"; do
        if [[ -f "$p" ]]; then prefs="$p"; break; fi
      done
      ;;
  esac
  if [[ -z "$plex_token" && -n "$prefs" && -f "$prefs" ]]; then
    plex_token="$(sed -n 's/.*PlexOnlineToken="\([^"]*\)".*/\1/p' "$prefs" | head -1)"
  fi

  sed -i.bak "s|^PLEX_URL=.*|PLEX_URL=$plex_url|" "$PROJECT_DIR/.env"
  ok "Plex detected on host: $plex_url"
  if [[ -n "$plex_token" ]]; then
    sed -i.bak "s|^PLEX_TOKEN=.*|PLEX_TOKEN=$plex_token|" "$PROJECT_DIR/.env"
    ok "Plex token extracted from host"
  else
    warn "Plex running but token not readable from registry/Preferences.xml"
    warn "Set PLEX_TOKEN manually in .env to enable Overseerr auto-wire"
  fi
  rm -f "$PROJECT_DIR/.env.bak"
  set -a; source "$PROJECT_DIR/.env"; set +a
}

generate_mobile_config() {
  info "Generating mobile configuration..."

  local lan_ip
  lan_ip="$(detect_lan_ip)"
  if [[ -z "$lan_ip" ]]; then
    lan_ip="YOUR_SERVER_IP"
    warn "Could not detect LAN IP — edit mobile-config.txt with your server IP"
  fi

  cat > "$PROJECT_DIR/mobile-config.txt" << MOBILEEOF
============================================================
  Media Center — Mobile App Configuration
============================================================

Server IP: $lan_ip

--- Services ---

Radarr (Movies):
  URL:     http://$lan_ip:7878
  API Key: ${RADARR_API_KEY:-not yet available}

Sonarr (TV):
  URL:     http://$lan_ip:8989
  API Key: ${SONARR_API_KEY:-not yet available}
MOBILEEOF

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    cat >> "$PROJECT_DIR/mobile-config.txt" << MOBILEEOF

Lidarr (Music):
  URL:     http://$lan_ip:8686
  API Key: ${LIDARR_API_KEY:-not yet available}

Overseerr (Requests):
  URL:     http://$lan_ip:5055
MOBILEEOF
  fi

  if [[ "$TIER" == "full" ]]; then
    cat >> "$PROJECT_DIR/mobile-config.txt" << MOBILEEOF

Readarr (Books):
  URL:     http://$lan_ip:8787
  API Key: ${READARR_API_KEY:-not yet available}
MOBILEEOF
  fi

  cat >> "$PROJECT_DIR/mobile-config.txt" << MOBILEEOF

qBittorrent:
  URL:     http://$lan_ip:8085
  User:    ${QB_USERNAME:-admin}
  Pass:    ${QB_PASSWORD:-mediaCenter!2026}

Plex (host, outside Docker):
  URL:     http://$lan_ip:32400/web

--- Mobile App Setup ---

iOS: Download "Ruddarr" from the App Store
  https://apps.apple.com/app/ruddarr/id6476240130
  - Open Ruddarr -> Add Instance
  - Enter the Radarr or Sonarr URL and API Key from above
  - Supports multiple instances (add both Radarr and Sonarr)

Android: Download "nzb360" from the Play Store
  - Open nzb360 -> Add Server
  - Enter each service URL and API Key from above

============================================================
  Generated by setup.sh on $(date '+%Y-%m-%d %H:%M')
============================================================
MOBILEEOF

  ok "Mobile config saved to mobile-config.txt"
}

configure_qbittorrent() {
  info "Configuring qBittorrent (via gluetun container)..."

  local qb_user="${QB_USERNAME:-admin}"
  local qb_pass="${QB_PASSWORD:-mediaCenter!2026}"

  # Get the temp password from logs for initial login
  local temp_pass
  temp_pass="$(docker logs qbittorrent 2>&1 | grep 'temporary password' | tail -1 | sed 's/.*session: //')"

  # Login with temp password from inside gluetun (shares qBittorrent's network)
  docker exec gluetun wget -qO /dev/null \
    --post-data="username=admin&password=$temp_pass" \
    --save-cookies /tmp/qb_cookies --keep-session-cookies \
    "http://localhost:8080/api/v2/auth/login" 2>/dev/null || true

  # Set permanent password, disable CSRF/host validation for Docker access, prevent IP bans
  local prefs_json
  prefs_json="{\"web_ui_username\":\"$qb_user\",\"web_ui_password\":\"$qb_pass\",\"save_path\":\"/data/torrents/\",\"temp_path_enabled\":false,\"web_ui_csrf_protection_enabled\":false,\"web_ui_host_header_validation_enabled\":false,\"web_ui_max_auth_fail_count\":0,\"web_ui_secure_cookie_enabled\":false}"
  docker exec gluetun wget -qO /dev/null \
    --post-data="json=$prefs_json" \
    --load-cookies /tmp/qb_cookies \
    "http://localhost:8080/api/v2/app/setPreferences" 2>/dev/null || true
  ok "qBittorrent password set (user: $qb_user)"

  # Re-login with new password for category setup
  docker exec gluetun wget -qO /dev/null \
    --post-data="username=$qb_user&password=$qb_pass" \
    --save-cookies /tmp/qb_cookies --keep-session-cookies \
    "http://localhost:8080/api/v2/auth/login" 2>/dev/null || true

  # Add categories
  for category in movies tv; do
    docker exec gluetun wget -qO /dev/null \
      --post-data="category=$category&savePath=/data/torrents/$category" \
      --load-cookies /tmp/qb_cookies \
      "http://localhost:8080/api/v2/torrents/createCategory" 2>/dev/null || true
  done

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    docker exec gluetun wget -qO /dev/null \
      --post-data="category=music&savePath=/data/torrents/music" \
      --load-cookies /tmp/qb_cookies \
      "http://localhost:8080/api/v2/torrents/createCategory" 2>/dev/null || true
  fi

  if [[ "$TIER" == "full" ]]; then
    docker exec gluetun wget -qO /dev/null \
      --post-data="category=books&savePath=/data/torrents/books" \
      --load-cookies /tmp/qb_cookies \
      "http://localhost:8080/api/v2/torrents/createCategory" 2>/dev/null || true
  fi

  ok "qBittorrent categories created"
}

# ==============================================================================
# Phase 8: Verify
# ==============================================================================
verify() {
  echo ""
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}  Media Center Setup Complete (${TIER})${NC}"
  echo -e "${BLUE}========================================${NC}"
  echo ""

  # VPN check
  local host_ip qbt_ip
  host_ip="$(curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")"
  qbt_ip="$(docker exec qbittorrent curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")"

  if [[ "$host_ip" != "$qbt_ip" && "$qbt_ip" != "unknown" ]]; then
    ok "VPN active — Host: $host_ip | Torrent: $qbt_ip"
  else
    warn "VPN check — Host: $host_ip | Torrent: $qbt_ip"
  fi

  echo ""
  echo "Service URLs:"
  echo "  qBittorrent:    http://localhost:8085"
  echo "  Prowlarr:       http://localhost:9696"
  echo "  FlareSolverr:   http://localhost:8191"
  echo "  Radarr:         http://localhost:7878"
  echo "  Sonarr:         http://localhost:8989"

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    echo "  Bazarr:         http://localhost:6767"
    echo "  Lidarr:         http://localhost:8686"
    echo "  Overseerr:      http://localhost:5055"
    echo "  Tautulli:       http://localhost:8181"
  fi

  if [[ "$TIER" == "full" ]]; then
    echo "  Readarr:        http://localhost:8787"
    echo "  Audiobookshelf: http://localhost:13378"
    echo "  Calibre-Web:    http://localhost:8083"
    echo "  Mylar3:         http://localhost:8090"
    echo "  Homarr:         http://localhost:7575"
  fi

  echo ""
  echo "qBittorrent login:"
  echo "  Username: ${QB_USERNAME:-admin}"
  echo "  Password: ${QB_PASSWORD:-mediaCenter!2026}"
  echo ""
  echo "What's been auto-configured:"
  echo "  - qBittorrent password, save path, and categories"
  echo "  - Radarr root folder + download client"
  echo "  - Sonarr root folder + download client"
  [[ "$TIER" == "standard" || "$TIER" == "full" ]] && echo "  - Lidarr root folder + download client"
  [[ "$TIER" == "full" ]] && echo "  - Readarr root folder + download client"
  echo "  - Prowlarr connected to all *arr apps"
  echo "  - FlareSolverr proxy in Prowlarr"
  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    if [[ -n "${PLEX_TOKEN:-}" ]]; then
      echo "  - Overseerr wired to Radarr + Sonarr"
    else
      echo "  - Overseerr skipped (set PLEX_TOKEN to auto-configure)"
    fi
  fi
  echo "  - API keys saved to .env"
  echo "  - Mobile config saved to mobile-config.txt"

  echo ""
  echo "Remaining manual steps:"
  echo "  1. Open Prowlarr (http://localhost:9696) and add your indexers."
  echo "     They will automatically sync to all connected *arr apps."
  if [[ "$TIER" == "standard" || "$TIER" == "full" ]] && [[ -z "${PLEX_TOKEN:-}" ]]; then
    echo "  2. Open Overseerr (http://localhost:5055) and complete setup wizard."
  fi
  echo ""
  echo "Mobile setup:"
  echo "  See mobile-config.txt for Ruddarr (iOS) / nzb360 (Android) setup."
  echo ""
}

# ==============================================================================
# Env Backup: push/pull .env via private GitHub Gist
# ==============================================================================
GIST_DESC="media-center-env-backup"

env_push() {
  if ! command -v gh &>/dev/null; then
    err "gh CLI is required. Install: https://cli.github.com/"
    exit 1
  fi

  if [[ ! -f "$PROJECT_DIR/.env" ]]; then
    err "No .env file to push."
    exit 1
  fi

  # Check for existing gist
  local gist_id
  gist_id="$(gh gist list --limit 100 2>/dev/null | grep "$GIST_DESC" | awk '{print $1}' | head -1 || true)"

  if [[ -n "$gist_id" ]]; then
    # Update existing gist
    gh gist edit "$gist_id" -a "$PROJECT_DIR/.env" 2>/dev/null
    ok "Updated .env in gist $gist_id"
  else
    # Create new secret gist (secret is the default, no flag needed)
    local gist_url
    gist_url="$(gh gist create -d "$GIST_DESC" "$PROJECT_DIR/.env" 2>&1)"
    ok "Created secret gist: $gist_url"
  fi
}

env_pull() {
  if ! command -v gh &>/dev/null; then
    err "gh CLI is required. Install: https://cli.github.com/"
    exit 1
  fi

  local gist_id
  gist_id="$(gh gist list --limit 100 2>/dev/null | grep "$GIST_DESC" | awk '{print $1}' | head -1 || true)"

  if [[ -z "$gist_id" ]]; then
    err "No saved .env found. Run './scripts/setup.sh push-env' first."
    exit 1
  fi

  # Pull the .env file from gist
  gh gist view "$gist_id" -r --filename .env > "$PROJECT_DIR/.env" 2>/dev/null
  ok "Pulled .env from gist $gist_id"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  # Handle push-env / pull-env commands
  case "${TIER}" in
    push-env)
      env_push
      exit 0
      ;;
    pull-env)
      env_pull
      exit 0
      ;;
  esac

  echo ""
  echo -e "${BLUE}=== Media Center Setup (tier: $TIER) ===${NC}"
  echo ""

  preflight
  setup_env
  create_dirs
  preconfigure_qbittorrent
  start_containers
  extract_api_keys
  configure_radarr
  configure_sonarr
  [[ "$TIER" == "standard" || "$TIER" == "full" ]] && configure_lidarr
  [[ "$TIER" == "full" ]] && configure_readarr
  configure_prowlarr
  [[ "$TIER" == "standard" || "$TIER" == "full" ]] && configure_overseerr
  configure_qbittorrent
  generate_mobile_config
  verify
}

main
