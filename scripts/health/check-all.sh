#!/usr/bin/env bash
# check-all.sh — Run all health checks for a node
# Usage: ./check-all.sh [container-name]
#
# Runs sync, peers, disk, and memory checks.
# For block producers, also runs KES check.

set -uo pipefail

CONTAINER="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
WARN=0
FAIL=0

run_check() {
    local name="$1"
    local script="$2"
    shift 2

    echo -e "\n${CYAN}─── ${name} ───${NC}"
    if "$SCRIPT_DIR/$script" "$@"; then
        ((PASS++))
    else
        local rc=$?
        if (( rc == 1 )); then
            ((WARN++))
        else
            ((FAIL++))
        fi
    fi
}

echo "╔══════════════════════════════════════╗"
echo "║      Hybrid-Node Health Report       ║"
echo "╚══════════════════════════════════════╝"

if [[ -n "$CONTAINER" ]]; then
    echo "Target: container ${CONTAINER}"
else
    echo "Target: local system"
fi

run_check "Sync Status"     check-sync.sh   "$CONTAINER"
run_check "Peer Status"     check-peers.sh  "$CONTAINER"
run_check "Disk Usage"      check-disk.sh
run_check "Memory Usage"    check-memory.sh "$CONTAINER"

# KES check only if MODE=bp or if explicitly running on a BP
if [[ "${NODE_MODE:-}" == "bp" ]] || [[ "${CHECK_KES:-}" == "Y" ]]; then
    run_check "KES Key Expiry" check-kes.sh "$CONTAINER"
fi

echo ""
echo "════════════════════════════════════════"
echo -e "Results: ${GREEN}${PASS} passed${NC} | ${YELLOW}${WARN} warnings${NC} | ${RED}${FAIL} failed${NC}"
echo "════════════════════════════════════════"

if (( FAIL > 0 )); then
    exit 2
elif (( WARN > 0 )); then
    exit 1
else
    exit 0
fi
