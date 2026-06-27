#!/usr/bin/env bash
# Unified activity monitor: GameSpy + DNS ports (tcpdump) + dwc/nginx container logs.
# Run on the VM while testing NDS connectivity.
#
# Verified ports (README + docker-compose):
#   TCP  443      nginx HTTPS (NAS login, DLC, stats HTTP)
#   TCP  29900     dwc GPCM profile
#   TCP  29901     dwc player search (GPSP)
#   TCP  29920     dwc gamestats
#   UDP  53        DNS sinkhole (iptables redirect to dnsmasq :5353)
#   UDP  27900     dwc GameSpy QR / availability
#   UDP  27901     dwc NAT negotiation
#   UDP  28910     dwc server browser
#
# Not in this monitor (HTTP only, no GameSpy): TCP 80 (nginx plain HTTP).
#
# Usage:
#   ./monitor.sh <CLIENT_IP>
#   ./monitor.sh 203.0.113.42
#   CLIENT_IP=203.0.113.42 ./monitor.sh
#   INTERFACE=ens4 ./monitor.sh 203.0.113.42
#   SKIP_TCPDUMP=1 ./monitor.sh 203.0.113.42    # logs only (no sudo)

set -euo pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[0;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

usage() {
  cat <<'EOF'
Usage: monitor.sh <CLIENT_IP>

  CLIENT_IP   Your NDS / hotspot public IP (changes each session).

Environment:
  CLIENT_IP, INTERFACE, SKIP_TCPDUMP, LOG_TAIL, DWC_CONTAINER, NGINX_CONTAINER

Examples:
  ./monitor.sh 203.0.113.42
  INTERFACE=ens4 ./monitor.sh 203.0.113.42
EOF
}

CLIENT_IP="${CLIENT_IP:-${1:-}}"
if [[ -z "$CLIENT_IP" ]]; then
  usage >&2
  exit 1
fi
if [[ ! "$CLIENT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%serror:%s invalid CLIENT_IP %q (expected IPv4)\n' "$RED" "$NC" "$CLIENT_IP" >&2
  exit 1
fi

readonly DWC_CONTAINER="${DWC_CONTAINER:-dwc}"
readonly NGINX_CONTAINER="${NGINX_CONTAINER:-nginx-nds-gateway}"
readonly INTERFACE="${INTERFACE:-$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}"
readonly LOG_TAIL="${LOG_TAIL:-30}"
readonly SKIP_TCPDUMP="${SKIP_TCPDUMP:-0}"

readonly TCP_PORTS=(443 29900 29901 29920)
readonly UDP_PORTS=(53 27900 27901 28910)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNLOGS_DIR="${SCRIPT_DIR}/runlogs"
mkdir -p "$RUNLOGS_DIR"
LOG_FILE="${RUNLOGS_DIR}/$(date +%Y-%m-%d_%H%M%S)_${CLIENT_IP}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

pids=()

cleanup() {
  printf '\n%sStopping monitor...%s\n' "$YELLOW" "$NC"
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
  exit 0
}

trap cleanup INT TERM

prefix_lines() {
  local tag="$1"
  local color="$2"
  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%b[%s]%b %s\n' "$color" "$tag" "$NC" "$line"
  done
}

build_tcpdump_filter() {
  local parts=()
  local port

  for port in "${TCP_PORTS[@]}"; do
    parts+=("tcp port ${port}")
  done
  for port in "${UDP_PORTS[@]}"; do
    parts+=("udp port ${port}")
  done

  local port_filter="${parts[0]}"
  local i
  for ((i = 1; i < ${#parts[@]}; i++)); do
    port_filter+=" or ${parts[$i]}"
  done
  printf 'host %s and (%s)' "$CLIENT_IP" "$port_filter"
}

check_prereqs() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%serror:%s docker not found\n' "$RED" "$NC" >&2
    exit 1
  fi

  if [[ -z "$INTERFACE" ]]; then
    printf '%serror:%s could not detect network interface; set INTERFACE=ens4\n' "$RED" "$NC" >&2
    exit 1
  fi

  if ! docker ps --format '{{.Names}}' | grep -qx "$DWC_CONTAINER"; then
    printf '%swarn:%s container %q is not running\n' "$YELLOW" "$NC" "$DWC_CONTAINER" >&2
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NGINX_CONTAINER"; then
    printf '%swarn:%s container %q is not running\n' "$YELLOW" "$NC" "$NGINX_CONTAINER" >&2
  fi
}

print_banner() {
  printf '%b=== Pokemon server activity monitor ===%b\n' "$BOLD" "$NC"
  printf 'client ip: %s (ports filter only)\n' "$CLIENT_IP"
  printf 'run log: %s\n' "$LOG_FILE"
  printf 'interface: %s\n' "$INTERFACE"
  printf 'tcp ports: %s\n' "${TCP_PORTS[*]}"
  printf 'udp ports: %s\n' "${UDP_PORTS[*]}"
  printf 'containers: %s, %s (unfiltered)\n' "$DWC_CONTAINER" "$NGINX_CONTAINER"
  printf '%sCtrl+C to stop%s\n\n' "$CYAN" "$NC"
}

start_docker_logs() {
  docker logs -f --tail "$LOG_TAIL" "$DWC_CONTAINER" 2>&1 \
    | prefix_lines "dwc" "$GREEN" &
  pids+=($!)

  docker logs -f --tail "$LOG_TAIL" "$NGINX_CONTAINER" 2>&1 \
    | prefix_lines "nginx" "$BLUE" &
  pids+=($!)
}

start_tcpdump() {
  if [[ "$SKIP_TCPDUMP" == "1" ]]; then
    printf '%sskip:%s SKIP_TCPDUMP=1 — port capture disabled\n' "$YELLOW" "$NC"
    return
  fi

  if ! command -v tcpdump >/dev/null 2>&1; then
    printf '%swarn:%s tcpdump not found; install with: sudo apt install tcpdump\n' "$YELLOW" "$NC"
    return
  fi

  local filter
  filter="$(build_tcpdump_filter)"

  # -l line-buffered; -nn no DNS/port names; -i interface
  sudo tcpdump -nni "$INTERFACE" -l "$filter" 2>&1 \
    | prefix_lines "ports" "$YELLOW" &
  pids+=($!)
}

check_prereqs
print_banner
start_docker_logs
start_tcpdump

wait
