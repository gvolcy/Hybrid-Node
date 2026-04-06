#!/usr/bin/env bash
# check-memory.sh — Check memory usage (system or container)
# Usage: ./check-memory.sh [container-name]
#
# Without a container name, checks system memory.
# With a container name, checks that container's memory via docker stats.

set -euo pipefail

CONTAINER="${1:-}"
WARN_THRESHOLD="${MEM_WARN_PCT:-80}"
CRIT_THRESHOLD="${MEM_CRIT_PCT:-90}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ -n "$CONTAINER" ]]; then
    # Container memory
    STATS=$(docker stats --no-stream --format '{{.MemUsage}} {{.MemPerc}}' "$CONTAINER" 2>/dev/null) || {
        echo -e "${RED}✗ Cannot get stats for container ${CONTAINER}${NC}"
        exit 1
    }
    MEM_USAGE=$(echo "$STATS" | awk '{print $1}')
    MEM_LIMIT=$(echo "$STATS" | awk '{print $3}')
    MEM_PCT=$(echo "$STATS" | awk '{print $NF}' | tr -d '%')
    echo "Memory: ${MEM_USAGE} / ${MEM_LIMIT} (${MEM_PCT}%)"
else
    # System memory
    TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
    USED=$(free -m | awk '/^Mem:/ {print $3}')
    AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
    MEM_PCT=$(( (USED * 100) / TOTAL ))
    echo "Memory: ${USED}M / ${TOTAL}M used (${MEM_PCT}%), ${AVAIL}M available"
fi

MEM_INT="${MEM_PCT%%.*}"

if (( MEM_INT >= CRIT_THRESHOLD )); then
    echo -e "${RED}✗ CRITICAL — memory usage ${MEM_PCT}%${NC}"
    exit 2
elif (( MEM_INT >= WARN_THRESHOLD )); then
    echo -e "${YELLOW}⚠ WARNING — memory usage ${MEM_PCT}%${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Memory healthy — ${MEM_PCT}% used${NC}"
    exit 0
fi
