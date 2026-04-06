#!/usr/bin/env bash
# check-disk.sh — Check disk usage for node data volumes
# Usage: ./check-disk.sh [mount-point]
#
# Defaults to /opt/cardano/cnode/db if no mount point specified.

set -euo pipefail

MOUNT="${1:-/opt/cardano/cnode/db}"
WARN_THRESHOLD="${DISK_WARN_PCT:-80}"
CRIT_THRESHOLD="${DISK_CRIT_PCT:-90}"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

USAGE=$(df "$MOUNT" 2>/dev/null | tail -1 | awk '{print $5}' | tr -d '%')

if [[ -z "$USAGE" ]]; then
    echo -e "${RED}✗ Cannot check disk for ${MOUNT}${NC}"
    exit 1
fi

SIZE=$(df -h "$MOUNT" | tail -1 | awk '{print $2}')
USED=$(df -h "$MOUNT" | tail -1 | awk '{print $3}')
AVAIL=$(df -h "$MOUNT" | tail -1 | awk '{print $4}')

echo "Disk: ${MOUNT} — ${USED}/${SIZE} (${USAGE}% used, ${AVAIL} free)"

if (( USAGE >= CRIT_THRESHOLD )); then
    echo -e "${RED}✗ CRITICAL — disk usage ${USAGE}% exceeds ${CRIT_THRESHOLD}%${NC}"
    exit 2
elif (( USAGE >= WARN_THRESHOLD )); then
    echo -e "${YELLOW}⚠ WARNING — disk usage ${USAGE}% exceeds ${WARN_THRESHOLD}%${NC}"
    exit 1
else
    echo -e "${GREEN}✓ Disk healthy — ${USAGE}% used${NC}"
    exit 0
fi
