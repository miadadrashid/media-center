#!/usr/bin/env bash
set -uo pipefail

# ==============================================================================
# VPN Shielding Verification
# Ensures ALL torrent traffic is behind the VPN. Run anytime.
# Usage: ./scripts/vpn-check.sh
# ==============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}  $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}  $*"; }
warn() { WARN_COUNT=$((WARN_COUNT + 1)); echo -e "  ${YELLOW}WARN${NC}  $*"; }

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  VPN Shielding Verification${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# Preflight — are containers running?
if ! docker inspect qbittorrent --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo -e "${RED}qBittorrent is not running. Start the stack first.${NC}"
  exit 1
fi
if ! docker inspect gluetun --format='{{.State.Running}}' 2>/dev/null | grep -q true; then
  echo -e "${RED}Gluetun is not running. Start the stack first.${NC}"
  exit 1
fi

HOST_IP="$(curl -sf --max-time 10 ifconfig.me || echo "")"
if [[ -z "$HOST_IP" ]]; then
  echo -e "${RED}Cannot determine host IP. Check internet connection.${NC}"
  exit 1
fi
echo "Host real IP: $HOST_IP"
echo ""

# ==================================================================
# TEST 1: IP Leak — two independent IP services
# ==================================================================
echo -e "${BLUE}--- 1. IP Leak Test ---${NC}"
QBT_IP1="$(docker exec qbittorrent curl -sf --max-time 10 ifconfig.me || echo "")"
QBT_IP2="$(docker exec qbittorrent curl -sf --max-time 10 https://api.ipify.org || echo "")"

if [[ -n "$QBT_IP1" && "$QBT_IP1" != "$HOST_IP" ]]; then
  pass "ifconfig.me: $QBT_IP1 (VPN)"
else
  fail "ifconfig.me: ${QBT_IP1:-no response} — REAL IP EXPOSED"
fi

if [[ -n "$QBT_IP2" && "$QBT_IP2" != "$HOST_IP" ]]; then
  pass "ipify.org:   $QBT_IP2 (VPN)"
else
  fail "ipify.org:   ${QBT_IP2:-no response} — REAL IP EXPOSED"
fi
echo ""

# ==================================================================
# TEST 2: DNS Leak
# ==================================================================
echo -e "${BLUE}--- 2. DNS Leak Test ---${NC}"
QBT_DNS="$(docker exec qbittorrent cat /etc/resolv.conf 2>/dev/null | grep nameserver | awk '{print $2}' | head -1)"
if [[ "$QBT_DNS" == "127.0.0.1" ]]; then
  pass "DNS resolver: 127.0.0.1 (gluetun encrypted DNS-over-TLS)"
else
  warn "DNS resolver: $QBT_DNS — may not be using VPN's encrypted DNS"
fi

# Check DNS leak via ipleak.net DNS test
DNS_SERVERS="$(docker exec qbittorrent curl -sf --max-time 10 'https://ipleak.net/json/' 2>/dev/null)"
if [[ -n "$DNS_SERVERS" ]]; then
  DNS_COUNTRY="$(echo "$DNS_SERVERS" | sed -n 's/.*"country_name":"\([^"]*\)".*/\1/p')"
  DNS_ISP="$(echo "$DNS_SERVERS" | sed -n 's/.*"isp_name":"\([^"]*\)".*/\1/p')"
  echo "  External check: ISP=$DNS_ISP, Country=$DNS_COUNTRY"
fi
echo ""

# ==================================================================
# TEST 3: Network Isolation — qBittorrent shares gluetun's stack
# ==================================================================
echo -e "${BLUE}--- 3. Network Isolation ---${NC}"
QBT_NETWORK="$(docker inspect qbittorrent --format='{{.HostConfig.NetworkMode}}')"
if [[ "$QBT_NETWORK" == "container:"* ]]; then
  GLUETUN_ID="$(docker inspect gluetun --format='{{.Id}}')"
  SHARED_ID="$(echo "$QBT_NETWORK" | sed 's/container://')"
  if [[ "$SHARED_ID" == "$GLUETUN_ID" ]]; then
    pass "qBittorrent network = gluetun container (verified by ID)"
  else
    fail "qBittorrent shares network with unknown container: $SHARED_ID"
  fi
else
  fail "qBittorrent network mode: $QBT_NETWORK — NOT sharing gluetun!"
fi

QBT_PORTS="$(docker inspect qbittorrent --format='{{.HostConfig.PortBindings}}')"
if [[ "$QBT_PORTS" == "map[]" || -z "$QBT_PORTS" ]]; then
  pass "No direct port bindings on qBittorrent"
else
  fail "qBittorrent has direct port bindings: $QBT_PORTS — LEAK RISK"
fi
echo ""

# ==================================================================
# TEST 4: Kill Switch — gluetun iptables default DROP
# ==================================================================
echo -e "${BLUE}--- 4. Kill Switch (iptables) ---${NC}"
OUTPUT_POLICY="$(docker exec gluetun iptables -L OUTPUT -n 2>/dev/null | head -1)"
if echo "$OUTPUT_POLICY" | grep -q "policy DROP"; then
  pass "OUTPUT chain default policy: DROP (kill switch active)"
else
  fail "OUTPUT chain: $OUTPUT_POLICY — no kill switch!"
fi

INPUT_POLICY="$(docker exec gluetun iptables -L INPUT -n 2>/dev/null | head -1)"
if echo "$INPUT_POLICY" | grep -q "policy DROP"; then
  pass "INPUT chain default policy: DROP"
else
  warn "INPUT chain: $INPUT_POLICY"
fi
echo ""

# ==================================================================
# TEST 5: VPN Tunnel Interface
# ==================================================================
echo -e "${BLUE}--- 5. VPN Tunnel Interface ---${NC}"
TUN_IP="$(docker exec qbittorrent ip addr show tun0 2>/dev/null | grep 'inet ' | awk '{print $2}')"
WG_IP="$(docker exec qbittorrent ip addr show wg0 2>/dev/null | grep 'inet ' | awk '{print $2}')"
if [[ -n "$TUN_IP" ]]; then
  pass "tun0 (OpenVPN): $TUN_IP"
elif [[ -n "$WG_IP" ]]; then
  pass "wg0 (WireGuard): $WG_IP"
else
  fail "No VPN tunnel interface (tun0/wg0) found!"
fi
echo ""

# ==================================================================
# TEST 6: IPv6 Leak
# ==================================================================
echo -e "${BLUE}--- 6. IPv6 Leak ---${NC}"
QBT_IPV6="$(docker exec qbittorrent curl -sf --max-time 5 -6 https://ifconfig.me 2>/dev/null || echo "")"
if [[ -z "$QBT_IPV6" ]]; then
  pass "No IPv6 connectivity (leak impossible)"
else
  HOST_IPV6="$(curl -sf --max-time 5 -6 https://ifconfig.me 2>/dev/null || echo "")"
  if [[ "$QBT_IPV6" != "$HOST_IPV6" || -z "$HOST_IPV6" ]]; then
    pass "IPv6 present but differs from host: $QBT_IPV6"
  else
    fail "IPv6 LEAK: qBittorrent exposes host IPv6: $QBT_IPV6"
  fi
fi
echo ""

# ==================================================================
# TEST 7: Gluetun Health
# ==================================================================
echo -e "${BLUE}--- 7. Gluetun Health ---${NC}"
GLUETUN_HEALTH="$(docker inspect --format='{{.State.Health.Status}}' gluetun 2>/dev/null || echo "unknown")"
if [[ "$GLUETUN_HEALTH" == "healthy" ]]; then
  pass "Gluetun status: healthy"
else
  fail "Gluetun status: $GLUETUN_HEALTH — VPN may be down!"
fi
echo ""

# ==================================================================
# SUMMARY
# ==================================================================
echo -e "${BLUE}============================================${NC}"
TOTAL=$((PASS_COUNT + FAIL_COUNT + WARN_COUNT))
echo -e "  ${GREEN}$PASS_COUNT passed${NC}, ${RED}$FAIL_COUNT failed${NC}, ${YELLOW}$WARN_COUNT warnings${NC} / $TOTAL total"

if [[ $FAIL_COUNT -gt 0 ]]; then
  echo ""
  echo -e "  ${RED}TORRENT TRAFFIC MAY BE EXPOSED — DO NOT USE UNTIL FIXED${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo ""
  exit 1
else
  echo ""
  echo -e "  ${GREEN}All torrent traffic is shielded behind the VPN.${NC}"
  echo -e "${BLUE}============================================${NC}"
  echo ""
  exit 0
fi
