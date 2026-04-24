#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Media Center — Integration Test Suite
# Usage: ./scripts/test.sh [minimal|standard|full]
# Tears down, runs setup from scratch, then asserts everything is wired correctly.
# Requires VPN credentials already in .env (or .env.example with creds).
# ==============================================================================

TIER="${1:-minimal}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# --- Colors ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $*"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo -e "  ${YELLOW}SKIP${NC}  $*"; }
section() { echo ""; echo -e "${BLUE}--- $* ---${NC}"; }

# --- Helpers ---
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    fail "$desc (expected: '$expected', got: '$actual')"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if echo "$haystack" | grep -q "$needle"; then
    pass "$desc"
  else
    fail "$desc (expected to contain: '$needle')"
  fi
}

assert_not_empty() {
  local desc="$1" value="$2"
  if [[ -n "$value" ]]; then
    pass "$desc"
  else
    fail "$desc (was empty)"
  fi
}

assert_container_running() {
  local name="$1"
  local status
  status="$(docker inspect --format='{{.State.Running}}' "$name" 2>/dev/null || echo "false")"
  if [[ "$status" == "true" ]]; then
    pass "Container $name is running"
  else
    fail "Container $name is NOT running"
  fi
}

assert_http_up() {
  local name="$1" url="$2"
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
  if [[ "$code" =~ ^[234] ]]; then
    pass "$name responds (HTTP $code)"
  else
    fail "$name not responding at $url (HTTP $code)"
  fi
}

api_get() {
  local url="$1" api_key="$2"
  curl -sf -H "X-Api-Key: $api_key" "$url" 2>/dev/null || echo ""
}

# --- Load .env ---
load_env() {
  if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a
    source "$PROJECT_DIR/.env"
    set +a
  fi
}

# ==============================================================================
# Teardown
# ==============================================================================
teardown() {
  section "Teardown"
  echo "  Stopping containers..."
  docker compose --project-directory "$PROJECT_DIR" --profile full down -v 2>/dev/null || true
  echo "  Removing data directories..."
  rm -rf "${HOME}/media-center-data"
  # Preserve VPN creds from .env if they exist
  local vpn_user="" vpn_pass="" vpn_provider="" vpn_type="" plex_token=""
  if [[ -f "$PROJECT_DIR/.env" ]]; then
    vpn_user="$(grep '^OPENVPN_USER=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    vpn_pass="$(grep '^OPENVPN_PASSWORD=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    vpn_provider="$(grep '^VPN_SERVICE_PROVIDER=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    vpn_type="$(grep '^VPN_TYPE=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
    plex_token="$(grep '^PLEX_TOKEN=' "$PROJECT_DIR/.env" | cut -d= -f2- || true)"
  fi
  rm -f "$PROJECT_DIR/.env"
  rm -f "$PROJECT_DIR/mobile-config.txt"

  # Run setup first time to generate .env
  "$SCRIPT_DIR/setup.sh" "$TIER" 2>/dev/null || true

  # Inject saved VPN creds back
  if [[ -n "$vpn_user" ]]; then
    sed -i.bak "s|^OPENVPN_USER=.*|OPENVPN_USER=$vpn_user|" "$PROJECT_DIR/.env"
    sed -i.bak "s|^OPENVPN_PASSWORD=.*|OPENVPN_PASSWORD=$vpn_pass|" "$PROJECT_DIR/.env"
    sed -i.bak "s|^VPN_SERVICE_PROVIDER=.*|VPN_SERVICE_PROVIDER=${vpn_provider:-nordvpn}|" "$PROJECT_DIR/.env"
    sed -i.bak "s|^VPN_TYPE=.*|VPN_TYPE=${vpn_type:-openvpn}|" "$PROJECT_DIR/.env"
    if [[ -n "$plex_token" ]]; then
      sed -i.bak "s|^PLEX_TOKEN=.*|PLEX_TOKEN=$plex_token|" "$PROJECT_DIR/.env"
    fi
    rm -f "$PROJECT_DIR/.env.bak"
  fi
  echo "  Teardown complete"
}

# ==============================================================================
# Run Setup
# ==============================================================================
run_setup() {
  section "Running setup.sh $TIER"
  "$SCRIPT_DIR/setup.sh" "$TIER" 2>&1
  load_env
}

# ==============================================================================
# Tests: Infrastructure (all tiers)
# ==============================================================================
test_infrastructure() {
  section "Infrastructure"

  # Containers running
  assert_container_running "gluetun"
  assert_container_running "qbittorrent"
  assert_container_running "prowlarr"
  assert_container_running "flaresolverr"

  # Gluetun healthy
  local gluetun_health
  gluetun_health="$(docker inspect --format='{{.State.Health.Status}}' gluetun 2>/dev/null || echo "none")"
  assert_eq "Gluetun is healthy" "healthy" "$gluetun_health"

  # VPN IP differs from host
  local host_ip qbt_ip
  host_ip="$(curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")"
  qbt_ip="$(docker exec qbittorrent curl -sf --max-time 5 ifconfig.me 2>/dev/null || echo "unknown")"
  if [[ "$host_ip" != "$qbt_ip" && "$qbt_ip" != "unknown" && "$host_ip" != "unknown" ]]; then
    pass "VPN active (host=$host_ip, torrent=$qbt_ip)"
  else
    fail "VPN not working (host=$host_ip, torrent=$qbt_ip)"
  fi

  # qBittorrent API accessible with configured password
  local qb_user="${QB_USERNAME:-admin}"
  local qb_pass="${QB_PASSWORD:-mediaCenter!2026}"
  local qb_login
  qb_login="$(curl -s http://localhost:8085/api/v2/auth/login -d "username=$qb_user&password=$qb_pass" 2>/dev/null)"
  assert_eq "qBittorrent login works" "Ok." "$qb_login"

  # qBittorrent save path
  local qb_cookie
  qb_cookie="$(curl -s -c - http://localhost:8085/api/v2/auth/login -d "username=$qb_user&password=$qb_pass" 2>/dev/null | grep SID | awk '{print $NF}')"
  local qb_prefs
  qb_prefs="$(curl -s -b "SID=$qb_cookie" http://localhost:8085/api/v2/app/preferences 2>/dev/null)"
  assert_contains "qBittorrent save path is /data/torrents/" "$qb_prefs" "/data/torrents/"

  # qBittorrent categories
  local qb_cats
  qb_cats="$(curl -s -b "SID=$qb_cookie" http://localhost:8085/api/v2/torrents/categories 2>/dev/null)"
  assert_contains "qBittorrent has 'movies' category" "$qb_cats" '"movies"'
  assert_contains "qBittorrent has 'tv' category" "$qb_cats" '"tv"'

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    assert_contains "qBittorrent has 'music' category" "$qb_cats" '"music"'
  fi
  if [[ "$TIER" == "full" ]]; then
    assert_contains "qBittorrent has 'books' category" "$qb_cats" '"books"'
  fi

  # Services responding
  assert_http_up "Prowlarr" "http://localhost:9696"
  assert_http_up "FlareSolverr" "http://localhost:8191"
}

# ==============================================================================
# Tests: Minimal tier
# ==============================================================================
test_minimal() {
  section "Minimal Tier (Radarr + Sonarr)"

  assert_container_running "radarr"
  assert_container_running "sonarr"
  assert_http_up "Radarr" "http://localhost:7878"
  assert_http_up "Sonarr" "http://localhost:8989"

  # API keys in .env
  assert_not_empty "RADARR_API_KEY in .env" "${RADARR_API_KEY:-}"
  assert_not_empty "SONARR_API_KEY in .env" "${SONARR_API_KEY:-}"
  assert_not_empty "PROWLARR_API_KEY in .env" "${PROWLARR_API_KEY:-}"

  # Radarr root folder
  local radarr_roots
  radarr_roots="$(api_get "http://localhost:7878/api/v3/rootfolder" "$RADARR_API_KEY")"
  assert_contains "Radarr root folder /data/media/movies" "$radarr_roots" "/data/media/movies"

  # Radarr download client
  local radarr_dl
  radarr_dl="$(api_get "http://localhost:7878/api/v3/downloadclient" "$RADARR_API_KEY")"
  assert_contains "Radarr has qBittorrent client" "$radarr_dl" "qBittorrent"

  # Sonarr root folder
  local sonarr_roots
  sonarr_roots="$(api_get "http://localhost:8989/api/v3/rootfolder" "$SONARR_API_KEY")"
  assert_contains "Sonarr root folder /data/media/tv" "$sonarr_roots" "/data/media/tv"

  # Sonarr download client
  local sonarr_dl
  sonarr_dl="$(api_get "http://localhost:8989/api/v3/downloadclient" "$SONARR_API_KEY")"
  assert_contains "Sonarr has qBittorrent client" "$sonarr_dl" "qBittorrent"

  # Prowlarr apps
  local prowlarr_apps
  prowlarr_apps="$(api_get "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY")"
  assert_contains "Prowlarr has Radarr app" "$prowlarr_apps" "Radarr"
  assert_contains "Prowlarr has Sonarr app" "$prowlarr_apps" "Sonarr"

  # Prowlarr FlareSolverr proxy
  local prowlarr_proxies
  prowlarr_proxies="$(api_get "http://localhost:9696/api/v1/indexerProxy" "$PROWLARR_API_KEY")"
  assert_contains "Prowlarr has FlareSolverr proxy" "$prowlarr_proxies" "FlareSolverr"

  # Prowlarr indexers
  local prowlarr_indexers
  prowlarr_indexers="$(api_get "http://localhost:9696/api/v1/indexer" "$PROWLARR_API_KEY")"
  assert_contains "Prowlarr has 1337x indexer" "$prowlarr_indexers" "1337x"
}

# ==============================================================================
# Tests: Standard tier
# ==============================================================================
test_standard() {
  section "Standard Tier (+ Lidarr, Bazarr, Overseerr, Tautulli)"

  assert_container_running "lidarr"
  assert_container_running "bazarr"
  assert_container_running "overseerr"
  assert_container_running "tautulli"

  assert_http_up "Lidarr" "http://localhost:8686"
  assert_http_up "Bazarr" "http://localhost:6767"
  assert_http_up "Overseerr" "http://localhost:5055"
  assert_http_up "Tautulli" "http://localhost:8181"

  assert_not_empty "LIDARR_API_KEY in .env" "${LIDARR_API_KEY:-}"

  # Lidarr root folder
  local lidarr_roots
  lidarr_roots="$(api_get "http://localhost:8686/api/v1/rootfolder" "$LIDARR_API_KEY")"
  assert_contains "Lidarr root folder /data/media/music" "$lidarr_roots" "/data/media/music"

  # Lidarr download client
  local lidarr_dl
  lidarr_dl="$(api_get "http://localhost:8686/api/v1/downloadclient" "$LIDARR_API_KEY")"
  assert_contains "Lidarr has qBittorrent client" "$lidarr_dl" "qBittorrent"

  # Prowlarr has Lidarr
  local prowlarr_apps
  prowlarr_apps="$(api_get "http://localhost:9696/api/v1/applications" "$PROWLARR_API_KEY")"
  assert_contains "Prowlarr has Lidarr app" "$prowlarr_apps" "Lidarr"

  # Overseerr wiring
  if [[ -n "${PLEX_TOKEN:-}" ]]; then
    # Check Overseerr has Radarr configured
    local os_cookie
    os_cookie="$(curl -s -c - -X POST http://localhost:5055/api/v1/auth/plex \
      -H "Content-Type: application/json" \
      -d "{\"authToken\":\"$PLEX_TOKEN\"}" 2>/dev/null | grep connect.sid | awk '{print $NF}')"

    local os_radarr
    os_radarr="$(curl -sf -b "connect.sid=$os_cookie" http://localhost:5055/api/v1/settings/radarr 2>/dev/null || echo "[]")"
    assert_contains "Overseerr has Radarr configured" "$os_radarr" "radarr"

    local os_sonarr
    os_sonarr="$(curl -sf -b "connect.sid=$os_cookie" http://localhost:5055/api/v1/settings/sonarr 2>/dev/null || echo "[]")"
    assert_contains "Overseerr has Sonarr configured" "$os_sonarr" "sonarr"
  else
    skip "Overseerr wiring (PLEX_TOKEN not set)"
  fi
}

# ==============================================================================
# Tests: Mobile config
# ==============================================================================
test_mobile_config() {
  section "Mobile Config"

  if [[ -f "$PROJECT_DIR/mobile-config.txt" ]]; then
    pass "mobile-config.txt exists"
    local config_content
    config_content="$(cat "$PROJECT_DIR/mobile-config.txt")"
    assert_contains "Has Radarr URL" "$config_content" ":7878"
    assert_contains "Has Sonarr URL" "$config_content" ":8989"
    assert_contains "Has API keys" "$config_content" "API Key"
    assert_contains "Has Ruddarr instructions" "$config_content" "Ruddarr"

    # Should use LAN IP, not localhost
    if echo "$config_content" | grep -q "localhost"; then
      fail "mobile-config.txt uses localhost (should use LAN IP)"
    else
      pass "mobile-config.txt uses LAN IP (not localhost)"
    fi
  else
    fail "mobile-config.txt does not exist"
  fi
}

# ==============================================================================
# Tests: Idempotency
# ==============================================================================
test_idempotency() {
  section "Idempotency (second run)"

  local output
  output="$("$SCRIPT_DIR/setup.sh" "$TIER" 2>&1)"

  # Should contain "already configured" or "skipping" messages
  assert_contains "Radarr skipped on re-run" "$output" "already configured\|skipping"
  assert_contains "No errors on re-run" "$output" "Setup Complete"

  # Verify no duplicate entries
  local radarr_roots
  radarr_roots="$(api_get "http://localhost:7878/api/v3/rootfolder" "$RADARR_API_KEY")"
  local root_count
  root_count="$(echo "$radarr_roots" | grep -o "/data/media/movies" | wc -l | tr -d ' ')"
  assert_eq "Radarr has exactly 1 root folder (no duplicates)" "1" "$root_count"
}

# ==============================================================================
# Main
# ==============================================================================
main() {
  echo ""
  echo -e "${BLUE}============================================${NC}"
  echo -e "${BLUE}  Media Center Test Suite (tier: $TIER)${NC}"
  echo -e "${BLUE}============================================${NC}"

  teardown
  run_setup

  test_infrastructure
  test_minimal

  if [[ "$TIER" == "standard" || "$TIER" == "full" ]]; then
    test_standard
  fi

  test_mobile_config
  test_idempotency

  # Summary
  echo ""
  echo -e "${BLUE}============================================${NC}"
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  echo -e "  Results: ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$SKIP_COUNT skipped${NC} / $total total"
  echo -e "${BLUE}============================================${NC}"
  echo ""

  if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
  fi
}

main
