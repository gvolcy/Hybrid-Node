#!/bin/bash
# DMQ Node Setup & Autostart Script
# Template: deploy to /opt/cardano/cnode/mithril/dmq-setup.sh in the pod
# Downloads and configures DMQ node on ephemeral storage, then starts it
# Called by autostart-signer-dmq.sh or manually
#
# Configuration:
#   - Update DMQ_VERSION when upgrading
#   - Update DMQ topology peers as needed
#   - Set --cardano-network-magic and --dmq-network-magic for your network
#     Preview: cardano-magic=2, dmq-magic=2147483650

set -e

DMQ_DIR="/home/guild/dmq"
DMQ_BIN="$DMQ_DIR/dmq-node"
DMQ_CONFIG="$DMQ_DIR/dmq.config.json"
DMQ_TOPOLOGY="$DMQ_DIR/dmq.topology.json"
DMQ_IPC_DIR="$DMQ_DIR/ipc"
DMQ_LOG="$DMQ_DIR/dmq.log"
DMQ_PID_FILE="$DMQ_DIR/dmq-node.pid"
DMQ_VERSION="0.4.2.0"
DMQ_DOWNLOAD_URL="https://github.com/IntersectMBO/dmq-node/releases/download/${DMQ_VERSION}/dmq-node-linux.tar.gz"
CARDANO_SOCKET="/opt/cardano/cnode/sockets/node.socket"

# Network magic — adjust per network
CARDANO_NETWORK_MAGIC=2              # Preview=2, Preprod=1, Mainnet=764824073
DMQ_NETWORK_MAGIC=2147483650         # Preview DMQ magic

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

log "DMQ Setup Script starting..."

# Check if DMQ node is already running
DMQ_LIVE_PID=$(ps -eo pid,stat,args | grep 'dmq-node' | grep -v grep | grep -v ' Z ' | awk '{print $1}' | head -1)
if [ -n "$DMQ_LIVE_PID" ]; then
    log "DMQ node already running (PID: $DMQ_LIVE_PID)"
    exit 0
fi

# Create DMQ directory structure
mkdir -p "$DMQ_DIR" "$DMQ_IPC_DIR"

# Download DMQ binary if missing
if [ ! -x "$DMQ_BIN" ]; then
    log "Downloading DMQ node $DMQ_VERSION..."
    cd /tmp
    curl -sL "$DMQ_DOWNLOAD_URL" -o dmq-node-linux.tar.gz
    tar xzf dmq-node-linux.tar.gz
    if [ -f result/bin/dmq-node ]; then
        mv result/bin/dmq-node "$DMQ_BIN"
        rm -rf result
    elif [ -f dmq-node ]; then
        mv dmq-node "$DMQ_BIN"
    else
        log "ERROR - dmq-node binary not found in tarball"
        rm -f dmq-node-linux.tar.gz
        exit 1
    fi
    chmod +x "$DMQ_BIN"
    rm -f dmq-node-linux.tar.gz
    log "DMQ node $DMQ_VERSION installed"
else
    log "DMQ binary already exists"
fi

# Write DMQ configuration (trace-dispatcher format for v0.4.x)
cat > "$DMQ_CONFIG" << 'DMQCFG'
{
  "PeerSharing": true,
  "LedgerPeers": false,
  "TraceOptions": {
    "": {
      "severity": "Notice",
      "backends": ["Stdout MachineFormat"]
    }
  }
}
DMQCFG

# Write DMQ topology — update peer addresses as needed
cat > "$DMQ_TOPOLOGY" << 'DMQTOPO'
{
  "localRoots": [
    {
      "accessPoints": [
        {
          "address": "34.76.22.193",
          "port": 6161
        }
      ],
      "advertise": false,
      "valency": 1,
      "trustable": true
    }
  ],
  "publicRoots": []
}
DMQTOPO

# Wait for Cardano node socket
if [ ! -S "$CARDANO_SOCKET" ]; then
    log "Waiting for Cardano node socket..."
    for i in $(seq 1 60); do
        [ -S "$CARDANO_SOCKET" ] && break
        sleep 5
    done
    if [ ! -S "$CARDANO_SOCKET" ]; then
        log "ERROR - Cardano node socket not available after 5 minutes"
        exit 1
    fi
fi

# Remove stale socket
rm -f "$DMQ_IPC_DIR/node.socket"

# Start DMQ node
log "Starting DMQ node v$DMQ_VERSION..."
cd "$DMQ_DIR"
nohup "$DMQ_BIN" \
    --host-addr 0.0.0.0 \
    -p 3141 \
    --local-socket "$DMQ_IPC_DIR/node.socket" \
    -c "$DMQ_CONFIG" \
    -t "$DMQ_TOPOLOGY" \
    --cardano-node-socket "$CARDANO_SOCKET" \
    --cardano-network-magic "$CARDANO_NETWORK_MAGIC" \
    --dmq-network-magic "$DMQ_NETWORK_MAGIC" \
    > "$DMQ_LOG" 2>&1 &

DMQ_PID=$!
echo "$DMQ_PID" > "$DMQ_PID_FILE"

# Verify it started
sleep 3
if ps -p "$DMQ_PID" > /dev/null 2>&1; then
    log "DMQ node started successfully (PID: $DMQ_PID)"
    for i in $(seq 1 10); do
        [ -S "$DMQ_IPC_DIR/node.socket" ] && break
        sleep 1
    done
    if [ -S "$DMQ_IPC_DIR/node.socket" ]; then
        log "DMQ socket ready at $DMQ_IPC_DIR/node.socket"
    else
        log "WARNING - DMQ socket not yet available"
    fi
else
    log "ERROR - DMQ node failed to start"
    tail -20 "$DMQ_LOG" 2>/dev/null
    exit 1
fi
