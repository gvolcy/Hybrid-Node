#!/usr/bin/env bash
# check-sync.sh — Check cardano-node sync progress
# Usage: ./check-sync.sh [container-name]
#
# Works for both Cardano and ApexFusion nodes.

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

SOCKET="/opt/cardano/cnode/sockets/node.socket"

# Get tip info
TIP=$(run_cmd cardano-cli query tip --socket-path "$SOCKET" 2>/dev/null) || {
    echo -e "${RED}✗ Cannot query node tip — is the node running?${NC}"
    exit 1
}

SLOT=$(echo "$TIP" | jq -r '.slot')
EPOCH=$(echo "$TIP" | jq -r '.epoch')
BLOCK=$(echo "$TIP" | jq -r '.block')
SYNC=$(echo "$TIP" | jq -r '.syncProgress')
HASH=$(echo "$TIP" | jq -r '.hash' | head -c 16)

if [[ "$SYNC" == "100.00" ]]; then
    echo -e "${GREEN}✓ SYNCED${NC} — epoch $EPOCH | block $BLOCK | slot $SLOT | hash ${HASH}…"
    exit 0
elif (( $(echo "$SYNC > 99.0" | bc -l 2>/dev/null || echo 0) )); then
    echo -e "${YELLOW}⟳ SYNCING${NC} — ${SYNC}% | epoch $EPOCH | block $BLOCK | slot $SLOT"
    exit 0
else
    echo -e "${RED}⟳ SYNCING${NC} — ${SYNC}% | epoch $EPOCH | block $BLOCK | slot $SLOT"
    exit 1
fi
