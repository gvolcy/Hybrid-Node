#!/usr/bin/env bash
# check-kes.sh — Check KES key expiry for block producers
# Usage: ./check-kes.sh [container-name]
#
# Alerts when KES period is within WARNING_PERIODS of expiry.
# KES keys must be rotated before they expire or the BP stops producing blocks.

set -euo pipefail

CONTAINER="${1:-}"
WARNING_PERIODS="${KES_WARNING_PERIODS:-5}"  # Warn when <= 5 periods remain
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

# Get KES info from Prometheus metrics
PROM_PORT="${PROMETHEUS_PORT:-12798}"
METRICS=$(run_cmd curl -sf "http://localhost:${PROM_PORT}/metrics" 2>/dev/null) || {
    echo -e "${RED}✗ Cannot reach metrics on port ${PROM_PORT}${NC}"
    exit 1
}

KES_CURRENT=$(echo "$METRICS" | grep 'cardano_node_metrics_currentKESPeriod_int' | awk '{print $2}' | head -1)
KES_REMAINING=$(echo "$METRICS" | grep 'cardano_node_metrics_remainingKESPeriods_int' | awk '{print $2}' | head -1)
KES_EXPIRY=$(echo "$METRICS" | grep 'cardano_node_metrics_operationalCertificateExpiryKESPeriod_int' | awk '{print $2}' | head -1)

KES_CURRENT="${KES_CURRENT:-unknown}"
KES_REMAINING="${KES_REMAINING:-unknown}"
KES_EXPIRY="${KES_EXPIRY:-unknown}"

# Remove decimals
KES_CURRENT="${KES_CURRENT%%.*}"
KES_REMAINING="${KES_REMAINING%%.*}"
KES_EXPIRY="${KES_EXPIRY%%.*}"

echo "KES: current=${KES_CURRENT} remaining=${KES_REMAINING} expiry=${KES_EXPIRY}"

if [[ "$KES_REMAINING" == "unknown" || "$KES_REMAINING" == "0" ]]; then
    echo -e "${RED}✗ KES key info unavailable or EXPIRED — rotate immediately!${NC}"
    exit 2
elif (( KES_REMAINING <= WARNING_PERIODS )); then
    echo -e "${YELLOW}⚠ KES key expiring soon — ${KES_REMAINING} periods remaining. Rotate now!${NC}"
    exit 1
else
    echo -e "${GREEN}✓ KES key healthy — ${KES_REMAINING} periods remaining${NC}"
    exit 0
fi
