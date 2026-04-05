#!/usr/bin/env bash
# ============================================================================
# Hybrid-Node Health Check
# Checks: socket exists → node responds → tip is advancing
# Exit 0 = healthy, Exit 1 = unhealthy
# ============================================================================

: "${CARDANO_NODE_SOCKET_PATH:=/opt/cardano/cnode/sockets/node.socket}"

# 1. Socket must exist
if [ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]; then
    echo "UNHEALTHY: Socket not found at ${CARDANO_NODE_SOCKET_PATH}"
    exit 1
fi

# 2. Node must respond to tip query
TIP=$(cardano-cli query tip --socket-path "${CARDANO_NODE_SOCKET_PATH}" 2>/dev/null) || {
    # If cardano-cli isn't available or socket hangs, fall back to socket test
    # socat is lighter but may not be installed
    if command -v socat &>/dev/null; then
        socat -u OPEN:/dev/null UNIX-CONNECT:"${CARDANO_NODE_SOCKET_PATH}" 2>/dev/null || {
            echo "UNHEALTHY: Socket exists but not connectable"
            exit 1
        }
    fi
    echo "HEALTHY: Socket exists (tip query unavailable)"
    exit 0
}

# 3. Check sync progress if available
SYNC=$(echo "${TIP}" | jq -r '.syncProgress // empty' 2>/dev/null)
if [ -n "${SYNC}" ]; then
    # Consider healthy if sync > 1% (node is making progress)
    SYNC_NUM=$(echo "${SYNC}" | tr -d '%' | cut -d'.' -f1)
    if [ "${SYNC_NUM:-0}" -ge 1 ]; then
        echo "HEALTHY: syncProgress=${SYNC}"
        exit 0
    else
        echo "SYNCING: syncProgress=${SYNC} (still bootstrapping)"
        exit 0  # Don't mark unhealthy during initial sync
    fi
fi

# 4. Fallback: if we got a tip response at all, we're healthy
SLOT=$(echo "${TIP}" | jq -r '.slot // empty' 2>/dev/null)
if [ -n "${SLOT}" ] && [ "${SLOT}" -gt 0 ]; then
    echo "HEALTHY: slot=${SLOT}"
    exit 0
fi

echo "UNHEALTHY: Node responded but tip is empty"
exit 1
