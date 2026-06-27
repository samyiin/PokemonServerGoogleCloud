#!/usr/bin/env bash
# Unified activity monitor: GameSpy + DNS ports (tcpdump) + dwc/nginx container logs.
# Run on the VM while testing NDS connectivity.
#
# Verified ports (README + docker-compose):
#   TCP  80, 443   nginx HTTP(S) — CLIENT_IP filter in tcpdump
#   UDP  53         DNS sinkhole — CLIENT_IP filter in tcpdump
#   TCP  29900, 29901, 29920   dwc GameSpy — all hosts
#   UDP  27900, 27901, 28910   dwc GameSpy — all hosts
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

# tcpdump: CLIENT_IP filter only on DNS + HTTP(S); GameSpy ports capture all hosts.
readonly TCP_PORTS_CLIENT_FILTER=(80 443)
readonly UDP_PORTS_CLIENT_FILTER=(53)
readonly TCP_PORTS_ALL=(29900 29901 29920)
readonly UDP_PORTS_ALL=(27900 27901 28910)

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

port_clauses() {
  local proto="$1"
  shift
  local port result="" first=1
  for port in "$@"; do
    if (( first )); then
      result="${proto} port ${port}"
      first=0
    else
      result+=" or ${proto} port ${port}"
    fi
  done
  printf '%s' "$result"
}

build_tcpdump_filter() {
  local client_tcp client_udp client_ports all_tcp all_udp all_ports

  client_tcp="$(port_clauses tcp "${TCP_PORTS_CLIENT_FILTER[@]}")"
  client_udp="$(port_clauses udp "${UDP_PORTS_CLIENT_FILTER[@]}")"
  client_ports="${client_tcp} or ${client_udp}"

  all_tcp="$(port_clauses tcp "${TCP_PORTS_ALL[@]}")"
  all_udp="$(port_clauses udp "${UDP_PORTS_ALL[@]}")"
  all_ports="${all_tcp} or ${all_udp}"

  printf '(host %s and (%s)) or (%s)' "$CLIENT_IP" "$client_ports" "$all_ports"
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
  printf 'client ip: %s (tcpdump filter on 53, 80, 443 only)\n' "$CLIENT_IP"
  printf 'run log: %s\n' "$LOG_FILE"
  printf 'interface: %s\n' "$INTERFACE"
  printf 'tcp ports (client filter): %s\n' "${TCP_PORTS_CLIENT_FILTER[*]}"
  printf 'udp ports (client filter): %s\n' "${UDP_PORTS_CLIENT_FILTER[*]}"
  printf 'tcp ports (all hosts): %s\n' "${TCP_PORTS_ALL[*]}"
  printf 'udp ports (all hosts): %s\n' "${UDP_PORTS_ALL[*]}"
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
