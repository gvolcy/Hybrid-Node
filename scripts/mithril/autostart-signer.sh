#!/bin/bash
# Mithril Signer Autostart Script (no DMQ)
# Template: deploy to /opt/cardano/cnode/mithril/autostart.sh in the pod
# Downloads stable mithril-signer if needed and starts it
# Called by mithril-keeper CronJob or manually
#
# Configuration:
#   - Update MITHRIL_RELEASE / MITHRIL_TAG when upgrading
#   - Requires mithril.env in the same directory
#   - See autostart-signer-dmq.sh for DMQ-enabled version

set -e

MITHRIL_DIR="/opt/cardano/cnode/mithril"
MITHRIL_ENV_FILE="$MITHRIL_DIR/mithril.env"
LOG_FILE="/opt/cardano/cnode/logs/mithril-signer.log"
SIGNER_BIN="/home/guild/.local/bin/mithril-signer"
PID_FILE="$MITHRIL_DIR/mithril-signer.pid"
CARDANO_SOCKET="/opt/cardano/cnode/sockets/node.socket"

# Stable signer version — update these when upgrading
MITHRIL_TAG="2478748"
MITHRIL_RELEASE="2617.0"
MITHRIL_URL="https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_RELEASE}/mithril-${MITHRIL_RELEASE}-linux-x64.tar.gz"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

log "Mithril Signer Autostart Script starting..."

# ---- Step 1: Ensure mithril-signer binary is installed ----
install_signer() {
    local current_version=""
    if [ -x "$SIGNER_BIN" ]; then
        current_version=$("$SIGNER_BIN" --version 2>&1 || echo "")
    fi

    if echo "$current_version" | grep -q "$MITHRIL_TAG"; then
        log "Mithril signer already at correct version: $current_version"
        return 0
    fi

    log "Installing mithril-signer (${MITHRIL_RELEASE} / ${MITHRIL_TAG})..."
    log "Current version: ${current_version:-not installed}"

    mkdir -p "$(dirname "$SIGNER_BIN")"
    cd /tmp

    curl -sL "$MITHRIL_URL" -o mithril-release.tar.gz
    tar xzf mithril-release.tar.gz
    if [ -f mithril-signer ]; then
        mv mithril-signer "$SIGNER_BIN"
        chmod +x "$SIGNER_BIN"
        rm -f mithril-release.tar.gz mithril-client mithril-aggregator mithril-relay 2>/dev/null
        log "Installed: $($SIGNER_BIN --version 2>&1)"
    else
        log "ERROR - mithril-signer not found in tarball"
        rm -f mithril-release.tar.gz
        return 1
    fi
}

# ---- Step 2: Start Mithril Signer ----
start_signer() {
    local SIGNER_LIVE_PID
    SIGNER_LIVE_PID=$(ps -eo pid,stat,args | grep 'mithril-signer' | grep -v grep | grep -v ' Z ' | awk '{print $1}' | head -1)
    if [ -n "$SIGNER_LIVE_PID" ]; then
        log "Mithril signer already running (PID: $SIGNER_LIVE_PID)"
        return 0
    fi

    if [ -f "$PID_FILE" ]; then
        local old_pid
        old_pid=$(cat "$PID_FILE")
        if ! ps -p "$old_pid" > /dev/null 2>&1 || ps -o stat= -p "$old_pid" 2>/dev/null | grep -q 'Z'; then
            log "Removing stale PID file"
            rm -f "$PID_FILE"
        fi
    fi

    if [ ! -S "$CARDANO_SOCKET" ]; then
        log "Waiting for Cardano node socket..."
        for i in $(seq 1 60); do
            [ -S "$CARDANO_SOCKET" ] && break
            sleep 5
        done
        if [ ! -S "$CARDANO_SOCKET" ]; then
            log "ERROR - Cardano node socket not available after 5 minutes"
            return 1
        fi
    fi

    if [ ! -f "$MITHRIL_ENV_FILE" ]; then
        log "ERROR - Mithril environment file not found: $MITHRIL_ENV_FILE"
        return 1
    fi

    if [ ! -x "$SIGNER_BIN" ]; then
        log "ERROR - Mithril signer binary not found: $SIGNER_BIN"
        return 1
    fi

    mkdir -p "$(dirname "$LOG_FILE")"

    log "Starting mithril-signer..."
    cd "$MITHRIL_DIR"
    set -a
    . "$MITHRIL_ENV_FILE"
    set +a

    nohup "$SIGNER_BIN" -vvv >> "$LOG_FILE" 2>&1 &
    local signer_pid=$!
    echo "$signer_pid" > "$PID_FILE"

    sleep 3
    if ps -p "$signer_pid" > /dev/null 2>&1; then
        log "Mithril signer started (PID: $signer_pid)"
        log "Network: $NETWORK | Party ID: $PARTY_ID"
        log "Aggregator: $AGGREGATOR_ENDPOINT"
        return 0
    else
        log "ERROR - Mithril signer failed to start"
        rm -f "$PID_FILE"
        tail -20 "$LOG_FILE" 2>/dev/null
        return 1
    fi
}

case "${1:-start}" in
    start)
        install_signer
        start_signer
        ;;
    status)
        echo "Mithril signer:"
        SIGNER_PID=$(ps -eo pid,stat,args | grep 'mithril-signer' | grep -v grep | grep -v ' Z ' | awk '{print $1}' | head -1)
        if [ -n "$SIGNER_PID" ]; then
            echo "  Running (PID: $SIGNER_PID)"
            echo "  Version: $($SIGNER_BIN --version 2>&1)"
        else
            echo "  Not running"
        fi
        ;;
    stop)
        log "Stopping mithril-signer..."
        pkill -f mithril-signer 2>/dev/null || true
        rm -f "$PID_FILE"
        log "Stopped"
        ;;
    restart)
        "$0" stop
        sleep 2
        "$0" start
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac
