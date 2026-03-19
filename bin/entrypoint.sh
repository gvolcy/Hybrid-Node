#!/usr/bin/env bash
# ============================================================================
# Hybrid-Node Entrypoint
# Handles: network config, mithril bootstrap, BP/relay mode, signal handling
# ============================================================================
set -eo pipefail

# ----- Colors for output -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[hybrid-node]${NC} $*"; }
warn() { echo -e "${YELLOW}[hybrid-node]${NC} WARN: $*"; }
err()  { echo -e "${RED}[hybrid-node]${NC} ERROR: $*" >&2; }

# ----- Defaults -----
: "${NETWORK:=mainnet}"
: "${NODE_MODE:=relay}"
: "${NODE_PORT:=6000}"
: "${CNODE_HOME:=/opt/cardano/cnode}"
: "${MITHRIL_DOWNLOAD:=N}"
: "${MITHRIL_SIGNER:=N}"
: "${UPDATE_CHECK:=N}"
: "${RTS_OPTS:=-N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return}"

export CNODE_HOME NODE_PORT NETWORK
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/db/node.socket"

DB_DIR="${CNODE_HOME}/db"
CONFIG_DIR="${CNODE_HOME}/files"
HYBRID_CONFIG_DIR="${CNODE_HOME}/hybrid-configs"

# ----- Signal handling -----
NODE_PID=""
SIGNER_PID=""

cleanup() {
    log "Received shutdown signal, cleaning up..."
    if [ -n "${SIGNER_PID}" ] && kill -0 "${SIGNER_PID}" 2>/dev/null; then
        log "Stopping mithril-signer (PID ${SIGNER_PID})..."
        kill -SIGTERM "${SIGNER_PID}" 2>/dev/null
        wait "${SIGNER_PID}" 2>/dev/null || true
    fi
    if [ -n "${NODE_PID}" ] && kill -0 "${NODE_PID}" 2>/dev/null; then
        log "Stopping cardano-node (PID ${NODE_PID})..."
        kill -SIGINT "${NODE_PID}" 2>/dev/null
        # cardano-node needs time for graceful shutdown
        local timeout=60
        while kill -0 "${NODE_PID}" 2>/dev/null && [ $timeout -gt 0 ]; do
            sleep 1
            timeout=$((timeout - 1))
        done
        if kill -0 "${NODE_PID}" 2>/dev/null; then
            warn "Node didn't stop gracefully, sending SIGKILL"
            kill -SIGKILL "${NODE_PID}" 2>/dev/null
        fi
    fi
    log "Shutdown complete."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ----- Network configuration -----
setup_network_configs() {
    log "Setting up network configs for: ${NETWORK}"

    # Map network names to IOG config URLs
    local BASE_URL=""
    case "${NETWORK}" in
        mainnet)
            BASE_URL="https://book.play.dev.cardano.org/environments/mainnet"
            ;;
        preview)
            BASE_URL="https://book.play.dev.cardano.org/environments/preview"
            ;;
        preprod)
            BASE_URL="https://book.play.dev.cardano.org/environments/preprod"
            ;;
        guild)
            BASE_URL="https://book.play.dev.cardano.org/environments/sanchonet"
            warn "Guild network uses sanchonet configs"
            ;;
        *)
            err "Unknown network: ${NETWORK}"
            err "Supported: mainnet, preview, preprod, guild"
            exit 1
            ;;
    esac

    # Check for user-provided config overrides
    if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ]; then
        log "Using custom config: ${CONFIG}"
        cp "${CONFIG}" "${CONFIG_DIR}/config.json"
    elif [ -f "${HYBRID_CONFIG_DIR}/${NETWORK}/config.json" ]; then
        log "Using hybrid config override for ${NETWORK}"
        cp "${HYBRID_CONFIG_DIR}/${NETWORK}/config.json" "${CONFIG_DIR}/config.json"
    elif [ ! -f "${CONFIG_DIR}/config.json" ]; then
        log "Downloading ${NETWORK} config.json..."
        curl -sS -o "${CONFIG_DIR}/config.json" "${BASE_URL}/config.json"
    fi

    if [ -n "${TOPOLOGY}" ] && [ -f "${TOPOLOGY}" ]; then
        log "Using custom topology: ${TOPOLOGY}"
        cp "${TOPOLOGY}" "${CONFIG_DIR}/topology.json"
    elif [ -f "${HYBRID_CONFIG_DIR}/${NETWORK}/topology.json" ]; then
        log "Using hybrid topology override for ${NETWORK}"
        cp "${HYBRID_CONFIG_DIR}/${NETWORK}/topology.json" "${CONFIG_DIR}/topology.json"
    elif [ ! -f "${CONFIG_DIR}/topology.json" ]; then
        log "Downloading ${NETWORK} topology.json..."
        curl -sS -o "${CONFIG_DIR}/topology.json" "${BASE_URL}/topology.json"
    fi

    # Download genesis files if missing
    for genesis in byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
        if [ ! -f "${CONFIG_DIR}/${genesis}" ]; then
            log "Downloading ${genesis}..."
            curl -sS -o "${CONFIG_DIR}/${genesis}" "${BASE_URL}/${genesis}" 2>/dev/null || \
                warn "Could not download ${genesis} (may not exist for this network)"
        fi
    done

    # Add custom peers to topology if specified
    if [ -n "${CUSTOM_PEERS}" ]; then
        log "Adding custom peers to topology..."
        add_custom_peers
    fi
}

# ----- Add custom peers to topology -----
add_custom_peers() {
    local topology="${CONFIG_DIR}/topology.json"
    if [ ! -f "${topology}" ]; then
        warn "No topology.json found, cannot add custom peers"
        return
    fi

    # Parse CUSTOM_PEERS format: addr1:port1,addr2:port2,...
    local peers_json="[]"
    IFS=',' read -ra PEER_LIST <<< "${CUSTOM_PEERS}"
    for peer in "${PEER_LIST[@]}"; do
        local addr port
        addr=$(echo "${peer}" | cut -d: -f1)
        port=$(echo "${peer}" | cut -d: -f2)
        port=${port:-3001}
        peers_json=$(echo "${peers_json}" | jq --arg a "${addr}" --arg p "${port}" \
            '. += [{"address": $a, "port": ($p | tonumber)}]')
    done

    # Merge into existing topology (P2P format)
    if jq -e '.localRoots' "${topology}" > /dev/null 2>&1; then
        # P2P topology format
        jq --argjson peers "${peers_json}" \
            '.localRoots += [{"accessPoints": $peers, "advertise": false, "trustable": false, "valency": ($peers | length)}]' \
            "${topology}" > "${topology}.tmp" && mv "${topology}.tmp" "${topology}"
        log "Added ${#PEER_LIST[@]} custom peers to P2P topology"
    fi
}

# ----- Mithril bootstrap -----
mithril_bootstrap() {
    if [ "${MITHRIL_DOWNLOAD}" != "Y" ] && [ "${MITHRIL_DOWNLOAD}" != "y" ]; then
        return
    fi

    # Skip if DB already exists and has meaningful data
    if [ -d "${DB_DIR}/immutable" ] && [ "$(ls -A "${DB_DIR}/immutable/" 2>/dev/null | wc -l)" -gt 0 ]; then
        log "Database already exists ($(du -sh "${DB_DIR}" | cut -f1)), skipping Mithril download"
        return
    fi

    if ! command -v mithril-client &>/dev/null; then
        warn "mithril-client not found, skipping bootstrap"
        return
    fi

    log "Bootstrapping ${NETWORK} database via Mithril..."

    # Set Mithril aggregator URL based on network
    local MITHRIL_AGGREGATOR=""
    case "${NETWORK}" in
        mainnet) MITHRIL_AGGREGATOR="https://aggregator.release-mainnet.api.mithril.network/aggregator" ;;
        preview) MITHRIL_AGGREGATOR="https://aggregator.testing-preview.api.mithril.network/aggregator" ;;
        preprod) MITHRIL_AGGREGATOR="https://aggregator.release-preprod.api.mithril.network/aggregator" ;;
        *)       warn "No Mithril aggregator for network ${NETWORK}"; return ;;
    esac

    export AGGREGATOR_ENDPOINT="${MITHRIL_AGGREGATOR}"
    export GENESIS_VERIFICATION_KEY=$(curl -sS "${MITHRIL_AGGREGATOR}/epoch-settings" | jq -r '.protocol_parameters.genesis_verification_key // empty' 2>/dev/null || true)

    if [ -z "${GENESIS_VERIFICATION_KEY}" ]; then
        warn "Could not fetch Mithril genesis verification key, skipping"
        return
    fi

    log "Downloading latest snapshot..."
    mithril-client cardano-db download latest --download-dir "${DB_DIR}" || {
        warn "Mithril download failed, node will sync from network"
    }
}

# ----- Start mithril-signer (BP mode) -----
start_mithril_signer() {
    if [ "${MITHRIL_SIGNER}" != "Y" ] && [ "${MITHRIL_SIGNER}" != "y" ]; then
        return
    fi

    if [ "${NODE_MODE}" != "bp" ]; then
        warn "Mithril signer only runs in BP mode"
        return
    fi

    if ! command -v mithril-signer &>/dev/null; then
        warn "mithril-signer not found, skipping"
        return
    fi

    log "Starting mithril-signer in background..."
    # Use guild's mithril-signer.sh if available, otherwise direct binary
    if [ -x "${CNODE_HOME}/scripts/mithril-signer.sh" ]; then
        bash "${CNODE_HOME}/scripts/mithril-signer.sh" &
        SIGNER_PID=$!
    else
        mithril-signer -vvv &
        SIGNER_PID=$!
    fi
    log "Mithril signer started (PID ${SIGNER_PID})"
}

# ----- Build cardano-node command -----
build_node_cmd() {
    local config_file="${CONFIG:-${CONFIG_DIR}/config.json}"
    local topology_file="${TOPOLOGY:-${CONFIG_DIR}/topology.json}"
    local db_path="${DB_DIR}"
    local socket_path="${CARDANO_NODE_SOCKET_PATH}"
    local host="0.0.0.0"

    # Validate required files
    if [ ! -f "${config_file}" ]; then
        err "Config file not found: ${config_file}"
        exit 1
    fi
    if [ ! -f "${topology_file}" ]; then
        err "Topology file not found: ${topology_file}"
        exit 1
    fi

    local CMD="cardano-node +RTS ${RTS_OPTS} -RTS run"
    CMD="${CMD} --config ${config_file}"
    CMD="${CMD} --topology ${topology_file}"
    CMD="${CMD} --database-path ${db_path}"
    CMD="${CMD} --socket-path ${socket_path}"
    CMD="${CMD} --host-addr ${host}"
    CMD="${CMD} --port ${NODE_PORT}"

    # BP-specific: KES keys
    if [ "${NODE_MODE}" = "bp" ]; then
        local priv="${CNODE_HOME}/priv"
        if [ -f "${priv}/pool/kes.skey" ] && [ -f "${priv}/pool/vrf.skey" ] && [ -f "${priv}/pool/node.cert" ]; then
            CMD="${CMD} --shelley-kes-key ${priv}/pool/kes.skey"
            CMD="${CMD} --shelley-vrf-key ${priv}/pool/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv}/pool/node.cert"
            log "Block producer mode: KES keys loaded"
        elif [ -f "${priv}/pool/hot.skey" ] && [ -f "${priv}/pool/vrf.skey" ] && [ -f "${priv}/pool/opcert.cert" ]; then
            # Alternative naming convention
            CMD="${CMD} --shelley-kes-key ${priv}/pool/hot.skey"
            CMD="${CMD} --shelley-vrf-key ${priv}/pool/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv}/pool/opcert.cert"
            log "Block producer mode: KES keys loaded (alt naming)"
        else
            warn "BP mode but no KES keys found in ${priv}/pool/"
            warn "Expected: kes.skey, vrf.skey, node.cert (or hot.skey, vrf.skey, opcert.cert)"
            warn "Starting as relay-equivalent (no block production)"
        fi
    fi

    echo "${CMD}"
}

# ----- Subcommand handling -----
case "${1:-}" in
    bash|sh)
        exec "$@"
        ;;
    cntools|cntool)
        exec bash "${CNODE_HOME}/scripts/cntools.sh" "${@:2}"
        ;;
    gliveview|gLiveView|glv)
        exec bash "${CNODE_HOME}/scripts/gLiveView.sh" "${@:2}"
        ;;
    nview)
        exec nview "${@:2}"
        ;;
    txtop)
        exec txtop "${@:2}"
        ;;
    cli)
        exec cardano-cli "${@:2}"
        ;;
    version|--version|-v)
        echo "=== Hybrid-Node Version Info ==="
        echo "cardano-node: $(cardano-node --version 2>/dev/null | head -1 || echo 'not found')"
        echo "cardano-cli:  $(cardano-cli --version 2>/dev/null | head -1 || echo 'not found')"
        echo "mithril-client: $(mithril-client --version 2>/dev/null | head -1 || echo 'not found')"
        echo "mithril-signer: $(mithril-signer --version 2>/dev/null | head -1 || echo 'not found')"
        echo "nview: $(nview --version 2>/dev/null | head -1 || echo 'not found')"
        echo "txtop: $(txtop --version 2>/dev/null | head -1 || echo 'not found')"
        echo "cncli: $(cncli --version 2>/dev/null | head -1 || echo 'not found')"
        echo "Network: ${NETWORK}"
        echo "Mode: ${NODE_MODE}"
        exit 0
        ;;
esac

# ===== Main flow =====
log "============================================"
log "  Hybrid-Node starting"
log "  Network: ${NETWORK}"
log "  Mode:    ${NODE_MODE}"
log "  Port:    ${NODE_PORT}"
log "============================================"

# Print version info
log "cardano-node $(cardano-node --version 2>/dev/null | head -1)"

# 1. Setup network configs
setup_network_configs

# 2. Mithril bootstrap (if enabled)
mithril_bootstrap

# 3. Build node command
NODE_CMD=$(build_node_cmd)
log "Starting: ${NODE_CMD}"

# 4. Launch cardano-node
eval ${NODE_CMD} &
NODE_PID=$!
log "cardano-node started (PID ${NODE_PID})"

# 5. Start mithril-signer if enabled (BP mode)
start_mithril_signer

# 6. Wait for node process
wait ${NODE_PID}
EXIT_CODE=$?
log "cardano-node exited with code ${EXIT_CODE}"
exit ${EXIT_CODE}
