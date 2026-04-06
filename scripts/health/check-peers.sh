#!/usr/bin/env bash
# check-peers.sh — Check cardano-node peer connections
# Usage: ./check-peers.sh [container-name]

set -euo pipefail

CONTAINER="${1:-}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_cmd() {
    if [[ -n "$CONTAINER" ]]; then
        docker exec "$CONTAINER" "$@"
    else
        "$@"
    fi
}


# Get peer count from EKG or Prometheus
PROM_PORT="${PROMETHEUS_PORT:-12798}"

METRICS=$(run_cmd curl -sf "http://localhost:${PROM_PORT}/metrics" 2>/dev/null) || {
    echo -e "${RED}✗ Cannot reach Prometheus metrics on port ${PROM_PORT}${NC}"
    exit 1
}

# Parse peer counts from Prometheus metrics
HOT=$(echo "$METRICS" | grep 'cardano_node_net_peers_hot{' | awk '{print $2}' | head -1)
WARM=$(echo "$METRICS" | grep 'cardano_node_net_peers_warm{' | awk '{print $2}' | head -1)
COLD=$(echo "$METRICS" | grep 'cardano_node_net_peers_cold{' | awk '{print $2}' | head -1)

HOT="${HOT:-0}"
WARM="${WARM:-0}"
COLD="${COLD:-0}"

# Remove decimals if present
HOT="${HOT%%.*}"
WARM="${WARM%%.*}"
COLD="${COLD%%.*}"

echo "Peers: hot=${HOT} warm=${WARM} cold=${COLD}"

if (( HOT >= 3 )); then
    echo -e "${GREEN}✓ Healthy peer count${NC}"
    exit 0
elif (( HOT >= 1 )); then
    echo -e "${YELLOW}⚠ Low peer count — hot peers: ${HOT}${NC}"
    exit 0
else
    echo -e "${RED}✗ No hot peers — node may be isolated${NC}"
    exit 1
fi
