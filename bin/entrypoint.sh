#!/usr/bin/env bash
# ============================================================================
# Hybrid-Node Entrypoint
# Handles: network config, mithril bootstrap, BP/relay mode, cncli processes,
#          PoolTool.io reporting, signal handling, graceful shutdown
# ============================================================================
set -eo pipefail

# ----- Colors for output -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[hybrid-node]${NC} $*"; }
warn() { echo -e "${YELLOW}[hybrid-node]${NC} WARN: $*" >&2; }
err()  { echo -e "${RED}[hybrid-node]${NC} ERROR: $*" >&2; }

# ----- Defaults -----
: "${NETWORK:=mainnet}"
: "${NODE_MODE:=relay}"
: "${NODE_PORT:=6000}"
: "${CNODE_HOME:=/opt/cardano/cnode}"
: "${CNODE_PORT:=${NODE_PORT}}"

# Auto-detect BP mode from CARDANO_BLOCK_PRODUCER or CNCLI_ENABLED
if [ "${CARDANO_BLOCK_PRODUCER}" = "true" ] && [ "${NODE_MODE}" = "relay" ]; then
    NODE_MODE="bp"
fi

# Sync NODE_PORT from CNODE_PORT if CNODE_PORT was explicitly set (K8s env)
if [ "${CNODE_PORT}" != "${NODE_PORT}" ]; then
    NODE_PORT="${CNODE_PORT}"
fi

# Compatibility: accept MITHRIL_SIGNER_ENABLED as alias for MITHRIL_SIGNER
if [ "${MITHRIL_SIGNER_ENABLED:-}" = "Y" ] && [ -z "${MITHRIL_SIGNER:-}" ]; then
    MITHRIL_SIGNER="Y"
fi

: "${MITHRIL_DOWNLOAD:=N}"
: "${MITHRIL_SIGNER:=N}"
: "${UPDATE_CHECK:=N}"
: "${CPU_CORES:=2}"
# Always rebuild RTS_OPTS to use actual CPU_CORES (Dockerfile bakes -N2 default)
RTS_OPTS="-N${CPU_CORES} -I0 -A16m -qg -qb --disable-delayed-os-memory-return"
: "${ENABLE_BACKUP:=N}"
: "${ENABLE_RESTORE:=N}"
: "${CNCLI_ENABLED:=N}"
: "${CARDANO_BLOCK_PRODUCER:=false}"
: "${EKG_HOST:=0.0.0.0}"
: "${EKG_PORT:=12788}"
: "${PROMETHEUS_HOST:=0.0.0.0}"
: "${PROMETHEUS_PORT:=12798}"

# Ensure EKG and Prometheus ports don't collide (they bind to separate sockets)
if [ "${EKG_PORT}" = "${PROMETHEUS_PORT}" ]; then
    EKG_PORT=$((PROMETHEUS_PORT + 10))
    log "WARN: EKG_PORT collided with PROMETHEUS_PORT (${PROMETHEUS_PORT}), adjusted EKG_PORT to ${EKG_PORT}"
fi
: "${IP_VERSION:=4}"
: "${CNODE_LISTEN_IP4:=0.0.0.0}"
: "${CNODE_LISTEN_IP6:=::}"
: "${MEMPOOL_OVERRIDE:=}"

# Pool configuration (BP mode)
: "${POOL_NAME:=}"
: "${POOL_DIR:=}"
: "${POOL_ID:=}"
: "${POOL_TICKER:=}"
: "${PT_API_KEY:=}"

export CNODE_HOME CNODE_PORT NODE_PORT NETWORK
export CARDANO_NODE_SOCKET_PATH="${CNODE_HOME}/sockets/node.socket"

DB_DIR="${CNODE_HOME}/db"
CONFIG_DIR="${CNODE_HOME}/files"
HYBRID_CONFIG_DIR="${CNODE_HOME}/hybrid-configs"
GUILD_DB_DIR="${CNODE_HOME}/guild-db"
LOGS_DIR="${CNODE_HOME}/logs"
SOCKETS_DIR="${CNODE_HOME}/sockets"
MITHRIL_DIR="${CNODE_HOME}/mithril"

# Ensure directories exist
mkdir -p "${DB_DIR}" "${CONFIG_DIR}" "${GUILD_DB_DIR}" "${LOGS_DIR}" "${SOCKETS_DIR}" "${MITHRIL_DIR}" "${CNODE_HOME}/priv/pool" "${CNODE_HOME}/scripts"

# ----- Signal handling -----
NODE_PID=""
SIGNER_PID=""
CNCLI_PIDS=()

cleanup() {
    log "Received shutdown signal, cleaning up..."

    # Stop cncli background processes
    for pid in "${CNCLI_PIDS[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            log "Stopping cncli process (PID ${pid})..."
            kill -SIGTERM "${pid}" 2>/dev/null || true
        fi
    done

    # Stop mithril-signer
    if [ -n "${SIGNER_PID}" ] && kill -0 "${SIGNER_PID}" 2>/dev/null; then
        log "Stopping mithril-signer (PID ${SIGNER_PID})..."
        kill -SIGTERM "${SIGNER_PID}" 2>/dev/null
        wait "${SIGNER_PID}" 2>/dev/null || true
    fi

    # Stop cardano-node with SIGINT (it expects SIGINT for graceful shutdown)
    if [ -n "${NODE_PID}" ] && kill -0 "${NODE_PID}" 2>/dev/null; then
        log "Stopping cardano-node (PID ${NODE_PID}) with SIGINT..."
        kill -SIGINT "${NODE_PID}" 2>/dev/null

        # Wait up to 280s for clean shutdown (checks for db/clean marker)
        local timeout=280
        while kill -0 "${NODE_PID}" 2>/dev/null && [ $timeout -gt 0 ]; do
            if [ -f "${DB_DIR}/clean" ]; then
                log "Clean shutdown confirmed (db/clean marker found)"
                break
            fi
            sleep 1
            timeout=$((timeout - 1))
        done

        if kill -0 "${NODE_PID}" 2>/dev/null; then
            warn "Node didn't stop gracefully after 280s, sending SIGKILL"
            kill -SIGKILL "${NODE_PID}" 2>/dev/null
        else
            log "cardano-node stopped gracefully"
        fi
    fi

    log "Shutdown complete."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# ----- Install runtime dependencies if missing -----
install_runtime_deps() {
    local need_install=false

    if ! command -v chattr &>/dev/null; then
        need_install=true
    fi
    if ! command -v sudo &>/dev/null; then
        need_install=true
    fi

    if [ "${need_install}" = true ]; then
        log "Installing runtime dependencies (e2fsprogs, sudo)..."
        apt-get update -qq 2>/dev/null && \
            apt-get install -y --no-install-recommends e2fsprogs sudo >/dev/null 2>&1 || \
            warn "Could not install e2fsprogs/sudo (running as non-root?)"

        # Configure sudo for CNTools chattr support
        if command -v sudo &>/dev/null; then
            if [ -w /etc/sudoers.d/ ]; then
                echo "guild ALL=NOPASSWD: /bin/chattr" > /etc/sudoers.d/cntools 2>/dev/null || true
                chmod 0440 /etc/sudoers.d/cntools 2>/dev/null || true
            fi
        fi
    fi
}

# ----- Pre-startup sanity checks (from Guild Operators cnode.sh) -----
pre_startup_sanity() {
    # Clean up stale socket from previous crash/restart
    if [ -S "${CARDANO_NODE_SOCKET_PATH}" ]; then
        if pgrep -f "cardano-node.*${CARDANO_NODE_SOCKET_PATH}" > /dev/null 2>&1; then
            err "A cardano-node is already running with this socket path!"
            err "Socket: ${CARDANO_NODE_SOCKET_PATH}"
            exit 1
        else
            log "Cleaning up stale socket from previous run..."
            rm -f "${CARDANO_NODE_SOCKET_PATH}"
        fi
    fi

    # Verify genesis hash sanity — recompute actual hashes and fix config.json
    # This prevents NetworkMagicMismatch and crypto hash mismatches
    check_genesis_hashes
}

# ----- Verify and fix genesis hashes in config.json (inspired by cnode.sh) -----
check_genesis_hashes() {
    local config_file="${CONFIG_DIR}/config.json"
    if [ ! -f "${config_file}" ]; then
        return  # config not yet downloaded, will be checked later
    fi

    if ! command -v cardano-cli &>/dev/null; then
        warn "cardano-cli not found, skipping genesis hash verification"
        return
    fi

    log "Verifying genesis hash integrity..."

    local needs_fix=false
    local byron_genesis="${CONFIG_DIR}/byron-genesis.json"
    local shelley_genesis="${CONFIG_DIR}/shelley-genesis.json"
    local alonzo_genesis="${CONFIG_DIR}/alonzo-genesis.json"
    local conway_genesis="${CONFIG_DIR}/conway-genesis.json"

    # Compute actual hashes from genesis files
    local byron_hash="" shelley_hash="" alonzo_hash="" conway_hash=""

    if [ -f "${byron_genesis}" ]; then
        byron_hash=$(cardano-cli byron genesis print-genesis-hash --genesis-json "${byron_genesis}" 2>/dev/null || true)
        local byron_cfg=$(jq -r '.ByronGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${byron_hash}" ] && [ "${byron_hash}" != "${byron_cfg}" ]; then
            warn "Byron genesis hash mismatch: config=${byron_cfg:0:16}... actual=${byron_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${shelley_genesis}" ]; then
        shelley_hash=$(cardano-cli hash genesis-file --genesis "${shelley_genesis}" 2>/dev/null || true)
        local shelley_cfg=$(jq -r '.ShelleyGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${shelley_hash}" ] && [ "${shelley_hash}" != "${shelley_cfg}" ]; then
            warn "Shelley genesis hash mismatch: config=${shelley_cfg:0:16}... actual=${shelley_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${alonzo_genesis}" ]; then
        alonzo_hash=$(cardano-cli hash genesis-file --genesis "${alonzo_genesis}" 2>/dev/null || true)
        local alonzo_cfg=$(jq -r '.AlonzoGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${alonzo_hash}" ] && [ "${alonzo_hash}" != "${alonzo_cfg}" ]; then
            warn "Alonzo genesis hash mismatch: config=${alonzo_cfg:0:16}... actual=${alonzo_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${conway_genesis}" ]; then
        conway_hash=$(cardano-cli hash genesis-file --genesis "${conway_genesis}" 2>/dev/null || true)
        local conway_cfg=$(jq -r '.ConwayGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${conway_hash}" ] && [ "${conway_hash}" != "${conway_cfg}" ]; then
            warn "Conway genesis hash mismatch: config=${conway_cfg:0:16}... actual=${conway_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ "${needs_fix}" = true ]; then
        log "Auto-fixing genesis hashes in config.json..."
        cp "${config_file}" "${config_file}.bak"

        local jq_args=()
        [ -n "${byron_hash}" ]   && jq_args+=(--arg bh "${byron_hash}")
        [ -n "${shelley_hash}" ] && jq_args+=(--arg sh "${shelley_hash}")
        [ -n "${alonzo_hash}" ]  && jq_args+=(--arg ah "${alonzo_hash}")
        [ -n "${conway_hash}" ]  && jq_args+=(--arg ch "${conway_hash}")

        local jq_expr=""
        [ -n "${byron_hash}" ]   && jq_expr+='.ByronGenesisHash = $bh | '
        [ -n "${shelley_hash}" ] && jq_expr+='.ShelleyGenesisHash = $sh | '
        [ -n "${alonzo_hash}" ]  && jq_expr+='.AlonzoGenesisHash = $ah | '
        [ -n "${conway_hash}" ]  && jq_expr+='.ConwayGenesisHash = $ch | '
        jq_expr="${jq_expr% | }"  # Remove trailing ' | '

        if jq "${jq_args[@]}" "${jq_expr}" "${config_file}" > "${config_file}.tmp" 2>/dev/null; then
            mv "${config_file}.tmp" "${config_file}"
            log "✅ Genesis hashes corrected in config.json"
        else
            warn "Failed to auto-fix genesis hashes, restoring backup"
            mv "${config_file}.bak" "${config_file}"
        fi
        rm -f "${config_file}.bak"
    else
        log "✅ Genesis hashes verified OK"
    fi
}

# ----- Customise Guild configs for monitoring access -----
customise_configs() {
    log "Customising config files for external access..."

    # Bind EKG and Prometheus to 0.0.0.0 instead of 127.0.0.1
    find "${CONFIG_DIR}" -name "*config*.json" -print0 2>/dev/null | \
        xargs -0 sed -i 's/127.0.0.1/0.0.0.0/g' 2>/dev/null || true

    # Ensure EnableP2P is set in config.json (node 10.6+ removed it from defaults
    # but Guild Operators gLiveView/env still reads it — defaults to false if missing)
    local main_config="${CONFIG_DIR}/config.json"
    if [ -f "${main_config}" ]; then
        local has_p2p
        has_p2p=$(jq -r '.EnableP2P // empty' "${main_config}" 2>/dev/null)
        if [ -z "${has_p2p}" ]; then
            log "Adding EnableP2P=true to config.json (required for gLiveView P2P detection)"
            jq '. + {"EnableP2P": true}' "${main_config}" > "${main_config}.tmp" && \
                mv "${main_config}.tmp" "${main_config}"
        fi

        # BP nodes: Switch GenesisMode → PraosMode
        # GenesisMode requires ≥5 big ledger peers to reach "CaughtUp" state, but a
        # locked-down BP only connects to its own relays (which aren't big ledger peers).
        # This leaves the node permanently stuck in "starting" / PreSyncing state.
        # PraosMode is the correct choice for BPs with restricted topology.
        # (Valid values: GenesisMode, PraosMode — CardanoMode was removed in 10.x)
        if [ "${NODE_MODE}" = "bp" ]; then
            local current_mode
            current_mode=$(jq -r '.ConsensusMode // empty' "${main_config}" 2>/dev/null)
            if [ "${current_mode}" = "GenesisMode" ]; then
                log "BP mode: Switching ConsensusMode from GenesisMode to PraosMode"
                jq '.ConsensusMode = "PraosMode"' "${main_config}" > "${main_config}.tmp" && \
                    mv "${main_config}.tmp" "${main_config}"
            fi
        fi

        # Use legacy tracing system for Guild Operators compatibility
        # The new trace dispatcher (UseTraceDispatcher=true) outputs minimal logs
        # that gLiveView/cntools can't fully parse (missing chainDensity, utxoSize,
        # delegMapSize, etc.) Legacy tracing with the full set of Trace* boolean flags
        # provides the detailed JSON traces and Prometheus metrics that Guild tools expect.
        # We also remove new-trace-dispatcher fields (TraceOptions, TraceOptionForwarder,
        # etc.) which conflict with legacy tracing, and add log rotation settings.
        local trace_dispatcher
        trace_dispatcher=$(jq -r 'if .UseTraceDispatcher == true then "true" elif .UseTraceDispatcher == false then "false" else "missing" end' "${main_config}" 2>/dev/null)
        local has_legacy_traces
        has_legacy_traces=$(jq -r 'if has("TraceMempool") then "yes" else "no" end' "${main_config}" 2>/dev/null)
        if [ "${trace_dispatcher}" = "true" ] || [ "${has_legacy_traces}" = "no" ]; then
            log "Configuring full legacy tracing (UseTraceDispatcher=false) for Guild tools compatibility"
            jq --argjson prom_p "${PROMETHEUS_PORT}" --argjson ekg_p "${EKG_PORT:-12788}" '
              .UseTraceDispatcher = false |
              del(.TraceOptions, .TraceOptionForwarder, .TraceOptionMetricsPrefix,
                  .TraceOptionResourceFrequency, .TraceOptionNodeName) |
              .defaultScribes = [["StdoutSK","stdout"]] |
              .setupScribes = [{"scFormat":"ScText","scKind":"StdoutSK","scName":"stdout","scRotation":null}] |
              .setupBackends = ["KatipBK"] |
              .defaultBackends = ["KatipBK"] |
              .minSeverity = "Info" |
              .TracingVerbosity = "NormalVerbosity" |
              .hasPrometheus = ["0.0.0.0", $prom_p] |
              .hasEKG = $ekg_p |
              .TraceAcceptPolicy = true |
              .TraceBlockFetchClient = false |
              .TraceBlockFetchDecisions = true |
              .TraceBlockFetchProtocol = false |
              .TraceBlockFetchProtocolSerialised = false |
              .TraceBlockFetchServer = false |
              .TraceChainDb = true |
              .TraceChainSyncBlockServer = false |
              .TraceChainSyncClient = false |
              .TraceChainSyncHeaderServer = false |
              .TraceChainSyncProtocol = false |
              .TraceConnectionManager = true |
              .TraceDNSResolver = true |
              .TraceDNSSubscription = true |
              .TraceDiffusionInitialization = true |
              .TraceErrorPolicy = true |
              .TraceForge = true |
              .TraceHandshake = true |
              .TraceInboundGovernor = true |
              .TraceIpSubscription = true |
              .TraceLedgerPeers = true |
              .TraceLocalChainSyncProtocol = false |
              .TraceLocalConnectionManager = true |
              .TraceLocalErrorPolicy = true |
              .TraceLocalHandshake = true |
              .TraceLocalRootPeers = true |
              .TraceLocalTxSubmissionProtocol = false |
              .TraceLocalTxSubmissionServer = false |
              .TraceMempool = true |
              .TraceMux = false |
              .TracePeerSelection = true |
              .TracePeerSelectionActions = true |
              .TracePublicRootPeers = true |
              .TraceServer = true |
              .TraceTxInbound = false |
              .TraceTxOutbound = false |
              .TraceTxSubmissionProtocol = false |
              .options = {
                "mapBackends": {
                  "cardano.node.metrics": ["EKGViewBK"],
                  "cardano.node.resources": ["EKGViewBK"]
                },
                "mapSubtrace": {
                  "cardano.node.metrics": {"subtrace":"Neutral"}
                }
              } |
              .rotation = {
                "rpKeepFilesNum": 10,
                "rpLogLimitBytes": 5000000,
                "rpMaxAgeHours": 24
              }
            ' "${main_config}" > "${main_config}.tmp" && \
                mv "${main_config}.tmp" "${main_config}"
        fi

        # Configure Guild env file with Prometheus/EKG endpoints
        # The newer Guild env script auto-detects Prometheus from TraceOptions (new
        # trace dispatcher format) but we use legacy tracing with hasPrometheus.
        # Explicitly set PROM_HOST/PROM_PORT so gLiveView can find metrics.
        local prom_host prom_port ekg_port
        prom_host=$(jq -r '.hasPrometheus[0] // empty' "${main_config}" 2>/dev/null)
        prom_port=$(jq -r '.hasPrometheus[1] // empty' "${main_config}" 2>/dev/null)
        # hasEKG can be integer (12788) or array (["0.0.0.0", 12788])
        ekg_port=$(jq -r 'if (.hasEKG | type) == "number" then .hasEKG elif (.hasEKG | type) == "array" then .hasEKG[1] else empty end' "${main_config}" 2>/dev/null)

        local env_file="${CNODE_HOME}/scripts/env"
        if [ -f "${env_file}" ] && [ -n "${prom_host}" ] && [ -n "${prom_port}" ]; then
            # Prometheus: uncomment and set, or add if not present
            sed -i "s|^#PROM_HOST=.*|PROM_HOST=${prom_host}|" "${env_file}" 2>/dev/null || true
            sed -i "s|^#PROM_PORT=.*|PROM_PORT=${prom_port}|" "${env_file}" 2>/dev/null || true
            # If already uncommented, update the value
            sed -i "s|^PROM_HOST=.*|PROM_HOST=${prom_host}|" "${env_file}" 2>/dev/null || true
            sed -i "s|^PROM_PORT=.*|PROM_PORT=${prom_port}|" "${env_file}" 2>/dev/null || true
            log "Set PROM_HOST=${prom_host} PROM_PORT=${prom_port} in env file"
        fi
        if [ -f "${env_file}" ] && [ -n "${ekg_port}" ]; then
            sed -i "s|^#EKG_PORT=.*|EKG_PORT=${ekg_port}|" "${env_file}" 2>/dev/null || true
            sed -i "s|^EKG_PORT=.*|EKG_PORT=${ekg_port}|" "${env_file}" 2>/dev/null || true
            log "Set EKG_PORT=${ekg_port} in env file"
        fi
    fi

    # Enable CHATTR in CNTools if available
    if [ -f "${CNODE_HOME}/scripts/cntools.sh" ]; then
        grep -qi ENABLE_CHATTR "${CNODE_HOME}/scripts/cntools.sh" 2>/dev/null && \
            sed -i 's/#ENABLE_CHATTR=false/ENABLE_CHATTR=true/g' "${CNODE_HOME}/scripts/cntools.sh" 2>/dev/null || true
    fi
}

# ----- Configure pool information in Guild scripts -----
configure_pool() {
    if [ "${NODE_MODE}" != "bp" ]; then
        return
    fi

    log "Configuring pool information..."

    # Set POOL_DIR default based on POOL_NAME if not explicitly set
    if [ -z "${POOL_DIR}" ] && [ -n "${POOL_NAME}" ]; then
        POOL_DIR="${CNODE_HOME}/priv/pool/${POOL_NAME}"
    fi

    # Configure Guild env file with pool information
    local env_file="${CNODE_HOME}/scripts/env"
    if [ -f "${env_file}" ]; then
        if [ -n "${POOL_NAME}" ]; then
            sed -i "s|#POOL_NAME=\"\"|POOL_NAME=\"${POOL_NAME}\"|g" "${env_file}" 2>/dev/null || true
            # Also update if already set to a different value
            sed -i "s|^POOL_NAME=.*|POOL_NAME=\"${POOL_NAME}\"|g" "${env_file}" 2>/dev/null || true
        fi
        if [ -n "${CNODE_PORT}" ]; then
            sed -i "s|#CNODE_PORT=.*|CNODE_PORT=${CNODE_PORT}|g" "${env_file}" 2>/dev/null || true
        fi
    fi

    # Configure cncli.sh with pool information
    local cncli_script="${CNODE_HOME}/scripts/cncli.sh"
    if [ -f "${cncli_script}" ]; then
        [ -n "${POOL_ID}" ] && \
            sed -i "s|POOL_ID=\".*\"|POOL_ID=\"${POOL_ID}\"|g" "${cncli_script}" 2>/dev/null || true
        [ -n "${POOL_TICKER}" ] && \
            sed -i "s|POOL_TICKER=\".*\"|POOL_TICKER=\"${POOL_TICKER}\"|g" "${cncli_script}" 2>/dev/null || true
        [ -n "${PT_API_KEY}" ] && \
            sed -i "s|PT_API_KEY=\".*\"|PT_API_KEY=\"${PT_API_KEY}\"|g" "${cncli_script}" 2>/dev/null || true
    fi

    log "Pool configured: name=${POOL_NAME:-unset} ticker=${POOL_TICKER:-unset} id=${POOL_ID:0:16}..."
}

# ----- DB backup / restore -----
handle_backup_restore() {
    if [ "${ENABLE_BACKUP}" != "Y" ] && [ "${ENABLE_RESTORE}" != "Y" ]; then
        return
    fi

    local backup_dir="${CNODE_HOME}/backup/${NETWORK}-db"
    mkdir -p "${backup_dir}"

    local dbsize=$(du -s "${DB_DIR}" 2>/dev/null | awk '{print $1}')
    local bksize=$(du -s "${backup_dir}" 2>/dev/null | awk '{print $1}')
    dbsize=${dbsize:-0}
    bksize=${bksize:-0}

    if [ "${ENABLE_RESTORE}" = "Y" ] && [ "${dbsize}" -lt "${bksize}" ]; then
        log "Restoring database from backup (${bksize}K > ${dbsize}K)..."
        cp -rf "${backup_dir}"/* "${DB_DIR}/" 2>/dev/null || true
        log "Database restore complete"
    fi

    if [ "${ENABLE_BACKUP}" = "Y" ] && [ "${dbsize}" -gt "${bksize}" ]; then
        log "Backing up database (${dbsize}K > ${bksize}K)..."
        cp -rf "${DB_DIR}"/* "${backup_dir}/" 2>/dev/null || true
        log "Database backup complete"
    fi
}

# ----- Network configuration -----
setup_network_configs() {
    log "Setting up network configs for: ${NETWORK}"

    # Determine config source URL based on network
    # Cardano networks: official IOG/cardano-playground configs
    # ApexFusion networks: Scitz0/guild-operators-apex configs (same cardano-node binary, different genesis)
    local BASE_URL=""
    local IS_APEX=false
    case "${NETWORK}" in
        mainnet) BASE_URL="https://book.play.dev.cardano.org/environments/mainnet" ;;
        preview) BASE_URL="https://book.play.dev.cardano.org/environments/preview" ;;
        preprod) BASE_URL="https://book.play.dev.cardano.org/environments/preprod" ;;
        guild)   BASE_URL="https://book.play.dev.cardano.org/environments/sanchonet"
                 warn "Guild network uses sanchonet configs" ;;
        afpm)    BASE_URL="https://raw.githubusercontent.com/Scitz0/guild-operators-apex/main/files/configs/afpm"
                 IS_APEX=true
                 log "ApexFusion Prime Mainnet (Vector chain)" ;;
        afpt)    BASE_URL="https://raw.githubusercontent.com/Scitz0/guild-operators-apex/main/files/configs/afpt"
                 IS_APEX=true
                 log "ApexFusion Prime Testnet (Vector chain)" ;;
        *)       err "Unknown network: ${NETWORK}. Supported: mainnet, preview, preprod, guild, afpm, afpt"; exit 1 ;;
    esac

    # Config file precedence: CLI override > hybrid-configs > network mismatch > existing > download
    if [ -n "${CONFIG}" ] && [ -f "${CONFIG}" ]; then
        log "Using custom config: ${CONFIG}"
        cp "${CONFIG}" "${CONFIG_DIR}/config.json"
    elif [ -f "${HYBRID_CONFIG_DIR}/${NETWORK}/config.json" ]; then
        log "Using hybrid config override for ${NETWORK}"
        cp "${HYBRID_CONFIG_DIR}/${NETWORK}/config.json" "${CONFIG_DIR}/config.json"
    elif [ -f "${CONFIG_DIR}/config.json" ]; then
        # Detect network mismatch: mainnet/afpm uses RequiresNoMagic, testnets use RequiresMagic
        local existing_magic
        existing_magic=$(jq -r '.RequiresNetworkMagic // empty' "${CONFIG_DIR}/config.json" 2>/dev/null)
        local expect_magic="RequiresMagic"
        [ "${NETWORK}" = "mainnet" ] && expect_magic="RequiresNoMagic"
        [ "${NETWORK}" = "afpm" ] && expect_magic="RequiresNoMagic"
        if [ -n "${existing_magic}" ] && [ "${existing_magic}" != "${expect_magic}" ]; then
            warn "Network mismatch! config.json has ${existing_magic} but NETWORK=${NETWORK} expects ${expect_magic}"
            log "Re-downloading correct ${NETWORK} config.json..."
            curl -sS -o "${CONFIG_DIR}/config.json" "${BASE_URL}/config.json"
        else
            log "Using existing config.json (preserving local modifications)"
        fi
    else
        log "Downloading ${NETWORK} config.json..."
        curl -sS -o "${CONFIG_DIR}/config.json" "${BASE_URL}/config.json"
    fi

    # Topology file precedence: CLI override > hybrid-configs > existing > download
    if [ -n "${TOPOLOGY}" ] && [ -f "${TOPOLOGY}" ]; then
        log "Using custom topology: ${TOPOLOGY}"
        # Avoid cp error when source and destination are the same file
        local topo_real dest_real
        topo_real=$(realpath "${TOPOLOGY}" 2>/dev/null || echo "${TOPOLOGY}")
        dest_real=$(realpath "${CONFIG_DIR}/topology.json" 2>/dev/null || echo "${CONFIG_DIR}/topology.json")
        if [ "${topo_real}" != "${dest_real}" ]; then
            cp "${TOPOLOGY}" "${CONFIG_DIR}/topology.json"
        fi
    elif [ -f "${HYBRID_CONFIG_DIR}/${NETWORK}/topology.json" ]; then
        log "Using hybrid topology override for ${NETWORK}"
        cp "${HYBRID_CONFIG_DIR}/${NETWORK}/topology.json" "${CONFIG_DIR}/topology.json"
    elif [ ! -f "${CONFIG_DIR}/topology.json" ]; then
        log "Downloading ${NETWORK} topology.json..."
        curl -sS -o "${CONFIG_DIR}/topology.json" "${BASE_URL}/topology.json"
    fi

    # Download genesis files for the requested network (always refresh to ensure correct network)
    for genesis in byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json; do
        if true; then
            log "Downloading ${genesis} for ${NETWORK}..."
            curl -sS -o "${CONFIG_DIR}/${genesis}" "${BASE_URL}/${genesis}" 2>/dev/null || \
                warn "Could not download ${genesis} (may not exist for this network)"
        fi
    done

    # APEX networks also use a genesis.json (byron-genesis alias used by some tools)
    if [ "${IS_APEX}" = true ]; then
        if [ -f "${CONFIG_DIR}/byron-genesis.json" ] && [ ! -f "${CONFIG_DIR}/genesis.json" ]; then
            cp "${CONFIG_DIR}/byron-genesis.json" "${CONFIG_DIR}/genesis.json"
            log "Created genesis.json symlink from byron-genesis.json (APEX compatibility)"
        fi
    fi

    # Download checkpoints.json if referenced by config (10.6+ for mainnet/preview)
    if jq -e '.CheckpointsFile' "${CONFIG_DIR}/config.json" >/dev/null 2>&1; then
        local ckpt_file
        ckpt_file=$(jq -r '.CheckpointsFile' "${CONFIG_DIR}/config.json")
        log "Downloading ${ckpt_file} for ${NETWORK}..."
        curl -sS -o "${CONFIG_DIR}/${ckpt_file}" "${BASE_URL}/${ckpt_file}" 2>/dev/null || \
            warn "Could not download ${ckpt_file} (may not exist for this network)"
    fi

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

    if jq -e '.localRoots' "${topology}" > /dev/null 2>&1; then
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

    if [ -d "${DB_DIR}/immutable" ] && [ "$(ls -A "${DB_DIR}/immutable/" 2>/dev/null | wc -l)" -gt 0 ]; then
        log "Database already exists ($(du -sh "${DB_DIR}" | cut -f1)), skipping Mithril download"
        return
    fi

    if ! command -v mithril-client &>/dev/null; then
        warn "mithril-client not found, skipping bootstrap"
        return
    fi

    log "Bootstrapping ${NETWORK} database via Mithril..."

    local MITHRIL_AGGREGATOR=""
    case "${NETWORK}" in
        mainnet) MITHRIL_AGGREGATOR="https://aggregator.release-mainnet.api.mithril.network/aggregator" ;;
        preview) MITHRIL_AGGREGATOR="https://aggregator.testing-preview.api.mithril.network/aggregator" ;;
        preprod) MITHRIL_AGGREGATOR="https://aggregator.release-preprod.api.mithril.network/aggregator" ;;
        afpm|afpt) log "Mithril not available for ApexFusion networks, skipping"; return ;;
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
    if [ "${MITHRIL_SIGNER}" != "Y" ] && [ "${MITHRIL_SIGNER}" != "y" ] && \
       [ "${MITHRIL_SIGNER_ENABLED}" != "Y" ]; then
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

    log "Scheduling mithril-signer startup (waits for node to be operational)..."
    (
        # Wait for cardano-node socket
        while [ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]; do
            sleep 10
        done
        log "  [mithril] Node socket ready ✓"

        # Wait for node to be responsive
        while ! timeout 10s cardano-cli query tip --socket-path "${CARDANO_NODE_SOCKET_PATH}" ${NETWORK_FLAG} >/dev/null 2>&1; do
            sleep 15
        done
        log "  [mithril] Node responding to queries ✓"

        # Wait for reasonable sync progress (>90%)
        while true; do
            local sync
            sync=$(timeout 10s cardano-cli query tip --socket-path "${CARDANO_NODE_SOCKET_PATH}" ${NETWORK_FLAG} 2>/dev/null | jq -r '.syncProgress // "0"' | sed 's/%//' || echo "0")
            if [ -n "${sync}" ] && [ "$(echo "${sync} > 90" | bc -l 2>/dev/null || echo 0)" -eq 1 ]; then
                log "  [mithril] Sync progress: ${sync}% ✓"
                break
            fi
            sleep 30
        done

        sleep 30
        log "🚀 Starting Mithril Signer..."

        # Load mithril environment if available
        if [ -f "${MITHRIL_DIR}/mithril.env" ]; then
            set -a && . "${MITHRIL_DIR}/mithril.env" && set +a
        fi

        export CARDANO_NODE_SOCKET_PATH="${CARDANO_NODE_SOCKET_PATH}"

        # Fix cardano_cli_path in config.toml if it points to a non-existent path
        local cli_real
        cli_real=$(command -v cardano-cli 2>/dev/null || echo "/usr/local/bin/cardano-cli")
        local mithril_cfg_dir="${MITHRIL_DIR}/config"
        if [ -f "${mithril_cfg_dir}/config.toml" ]; then
            sed -i "s|^cardano_cli_path = .*|cardano_cli_path = \"${cli_real}\"|" "${mithril_cfg_dir}/config.toml"
            log "  [mithril] Updated cardano_cli_path → ${cli_real}"
        fi

        # Determine metrics settings from mithril.env (default 9090)
        local m_ip="${METRICS_SERVER_IP:-0.0.0.0}"
        local m_port="${METRICS_SERVER_PORT:-9090}"

        # Always start mithril-signer directly (skip guild-ops mithril-signer.sh
        # which needs its own env setup that may not exist in the container)
        if [ -d "${mithril_cfg_dir}" ]; then
            log "  [mithril] Using config dir: ${mithril_cfg_dir}"
            nohup mithril-signer \
                -c "${mithril_cfg_dir}" \
                --enable-metrics-server \
                --metrics-server-ip "${m_ip}" \
                --metrics-server-port "${m_port}" \
                -vv >> "${LOGS_DIR}/mithril-signer.log" 2>&1 &
        else
            nohup mithril-signer \
                --enable-metrics-server \
                --metrics-server-ip "${m_ip}" \
                --metrics-server-port "${m_port}" \
                -vv >> "${LOGS_DIR}/mithril-signer.log" 2>&1 &
        fi
        SIGNER_PID=$!
        log "✅ Mithril signer started (PID: ${SIGNER_PID})"
        log "📊 Metrics: http://localhost:${m_port}/metrics"
        log "📝 Logs: ${LOGS_DIR}/mithril-signer.log"
    ) &
}

# ----- Start CNCLI background processes (BP mode) -----
start_cncli_processes() {
    if [ "${NODE_MODE}" != "bp" ]; then
        return
    fi

    if [ "${CNCLI_ENABLED}" != "Y" ] && [ "${CNCLI_ENABLED}" != "y" ]; then
        return
    fi

    if [ ! -f "${CNODE_HOME}/scripts/cncli.sh" ]; then
        warn "cncli.sh not found, skipping CNCLI processes"
        return
    fi

    log "Scheduling CNCLI background processes (waits for node startup)..."
    (
        # Wait for cardano-node socket
        while [ ! -S "${CARDANO_NODE_SOCKET_PATH}" ]; do
            sleep 10
        done

        # Give node time to fully start and open EKG/Prometheus ports
        log "  [cncli] Waiting 30s for cardano-node ports..."
        sleep 30

        mkdir -p "${GUILD_DB_DIR}"

        # Backup existing cncli database
        if [ -f "${GUILD_DB_DIR}/cncli.db" ]; then
            log "  [cncli] Found existing cncli database - preserving"
            cp "${GUILD_DB_DIR}/cncli.db" "${GUILD_DB_DIR}/cncli.db.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi

        # Start PoolTool.io sendtip/sendslots if API key is available
        if [ -n "${PT_API_KEY}" ]; then
            log "  [cncli] Starting PoolTool.io sendtip..."
            "${CNODE_HOME}/scripts/cncli.sh" ptsendtip >> "${GUILD_DB_DIR}/ptsendtip.log" 2>&1 &
            CNCLI_PIDS+=($!)
            "${CNODE_HOME}/scripts/cncli.sh" ptsendslots >> "${GUILD_DB_DIR}/ptsendslots.log" 2>&1 &
            CNCLI_PIDS+=($!)
        else
            log "  [cncli] PT_API_KEY not set - skipping PoolTool.io (get key from pooltool.io)"
        fi

        # Start core CNCLI processes
        log "  [cncli] Starting sync, leaderlog, validate..."
        "${CNODE_HOME}/scripts/cncli.sh" sync >> "${GUILD_DB_DIR}/sync.log" 2>&1 &
        CNCLI_PIDS+=($!)
        "${CNODE_HOME}/scripts/cncli.sh" leaderlog >> "${GUILD_DB_DIR}/leader.log" 2>&1 &
        CNCLI_PIDS+=($!)
        "${CNODE_HOME}/scripts/cncli.sh" validate >> "${GUILD_DB_DIR}/validate.log" 2>&1 &
        CNCLI_PIDS+=($!)

        log "✅ CNCLI processes started (${#CNCLI_PIDS[@]} processes)"
    ) &
}

# ----- Build cardano-node command -----
build_node_cmd() {
    local config_file="${CONFIG:-${CONFIG_DIR}/config.json}"
    local topology_file="${TOPOLOGY:-${CONFIG_DIR}/topology.json}"
    local db_path="${DB_DIR}"
    local socket_path="${CARDANO_NODE_SOCKET_PATH}"

    if [ ! -f "${config_file}" ]; then
        err "Config file not found: ${config_file}"; exit 1
    fi
    if [ ! -f "${topology_file}" ]; then
        err "Topology file not found: ${topology_file}"; exit 1
    fi

    local CMD="cardano-node +RTS ${RTS_OPTS} -RTS run"
    CMD="${CMD} --config ${config_file}"
    CMD="${CMD} --topology ${topology_file}"
    CMD="${CMD} --database-path ${db_path}"
    CMD="${CMD} --socket-path ${socket_path}"

    # IPv4/IPv6/dual-stack support (IP_VERSION: 4, 6, or mix)
    local ip_ver
    ip_ver=$(echo "${IP_VERSION}" | tr '[:upper:]' '[:lower:]')
    if [ "${ip_ver}" = "4" ] || [ "${ip_ver}" = "mix" ]; then
        CMD="${CMD} --host-addr ${CNODE_LISTEN_IP4}"
    fi
    if [ "${ip_ver}" = "6" ] || [ "${ip_ver}" = "mix" ]; then
        CMD="${CMD} --host-ipv6-addr ${CNODE_LISTEN_IP6}"
    fi

    CMD="${CMD} --port ${NODE_PORT}"

    # Mempool override (e.g. --mempool-capacity-override <bytes>)
    if [ -n "${MEMPOOL_OVERRIDE}" ]; then
        CMD="${CMD} ${MEMPOOL_OVERRIDE}"
    fi

    # BP-specific: KES keys
    if [ "${NODE_MODE}" = "bp" ]; then
        local priv_pool=""
        if [ -n "${POOL_DIR}" ] && [ -d "${POOL_DIR}" ]; then
            priv_pool="${POOL_DIR}"
        elif [ -n "${POOL_NAME}" ] && [ -d "${CNODE_HOME}/priv/pool/${POOL_NAME}" ]; then
            priv_pool="${CNODE_HOME}/priv/pool/${POOL_NAME}"
        else
            priv_pool="${CNODE_HOME}/priv/pool"
        fi

        # Try Guild naming: hot.skey, vrf.skey, op.cert
        if [ -f "${priv_pool}/hot.skey" ] && [ -f "${priv_pool}/vrf.skey" ] && [ -f "${priv_pool}/op.cert" ]; then
            CMD="${CMD} --shelley-kes-key ${priv_pool}/hot.skey"
            CMD="${CMD} --shelley-vrf-key ${priv_pool}/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv_pool}/op.cert"
            log "BP mode: KES keys loaded from ${priv_pool} (Guild naming)" >&2
        # Try CoinCashew naming: kes.skey, vrf.skey, node.cert
        elif [ -f "${priv_pool}/kes.skey" ] && [ -f "${priv_pool}/vrf.skey" ] && [ -f "${priv_pool}/node.cert" ]; then
            CMD="${CMD} --shelley-kes-key ${priv_pool}/kes.skey"
            CMD="${CMD} --shelley-vrf-key ${priv_pool}/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv_pool}/node.cert"
            log "BP mode: KES keys loaded from ${priv_pool} (CoinCashew naming)" >&2
        # Try alt naming: hot.skey, vrf.skey, opcert.cert
        elif [ -f "${priv_pool}/hot.skey" ] && [ -f "${priv_pool}/vrf.skey" ] && [ -f "${priv_pool}/opcert.cert" ]; then
            CMD="${CMD} --shelley-kes-key ${priv_pool}/hot.skey"
            CMD="${CMD} --shelley-vrf-key ${priv_pool}/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv_pool}/opcert.cert"
            log "BP mode: KES keys loaded from ${priv_pool} (alt naming)" >&2
        else
            warn "BP mode but no KES keys found in ${priv_pool}/"
            warn "Expected one of:"
            warn "  Guild:      hot.skey, vrf.skey, op.cert"
            warn "  CoinCashew: kes.skey, vrf.skey, node.cert"
            warn "  Alt:        hot.skey, vrf.skey, opcert.cert"
            warn "Starting as relay-equivalent (no block production)"
            ls -la "${priv_pool}/" >&2 2>&1 || warn "Directory does not exist: ${priv_pool}"
        fi
    fi

    echo "${CMD}"
}

# ----- Determine --mainnet / --testnet-magic flag for cardano-cli -----
get_network_flag() {
    case "${NETWORK}" in
        mainnet) echo "--mainnet" ;;
        afpm)    echo "--mainnet" ;;
        preview) echo "--testnet-magic 2" ;;
        preprod) echo "--testnet-magic 1" ;;
        guild)   echo "--testnet-magic 141" ;;
        afpt)    echo "--testnet-magic 3311" ;;
        *)       echo "--mainnet" ;;
    esac
}

NETWORK_FLAG=$(get_network_flag)

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
    cncli)
        exec bash "${CNODE_HOME}/scripts/cncli.sh" "${@:2}"
        ;;
    topologyUpdater|topology-updater)
        exec bash "${CNODE_HOME}/scripts/topologyUpdater.sh" "${@:2}"
        ;;
    version|--version|-v)
        echo "=== Hybrid-Node Version Info ==="
        echo "cardano-node:   $(cardano-node --version 2>/dev/null | head -1 || echo 'not found')"
        echo "cardano-cli:    $(cardano-cli --version 2>/dev/null | head -1 || echo 'not found')"
        echo "mithril-client: $(mithril-client --version 2>/dev/null | head -1 || echo 'not found')"
        echo "mithril-signer: $(mithril-signer --version 2>/dev/null | head -1 || echo 'not found')"
        echo "nview:          $(nview --version 2>/dev/null | head -1 || echo 'not found')"
        echo "txtop:          $(txtop --version 2>/dev/null | head -1 || echo 'not found')"
        echo "cncli:          $(cncli --version 2>/dev/null | head -1 || echo 'not found')"
        echo "Network: ${NETWORK}"
        echo "Mode:    ${NODE_MODE}"
        echo "Port:    ${NODE_PORT}"
        echo "CPU:     ${CPU_CORES}"
        exit 0
        ;;
esac

# ===== Main flow =====
log "============================================"
log "  Hybrid-Node starting"
log "  Network:    ${NETWORK}"
log "  Mode:       ${NODE_MODE}"
log "  Port:       ${NODE_PORT}"
log "  CPU Cores:  ${CPU_CORES}"
log "  IP Version: ${IP_VERSION}"
log "  Socket:     ${CARDANO_NODE_SOCKET_PATH}"
if [ "${NODE_MODE}" = "bp" ]; then
    log "  Pool:       ${POOL_NAME:-unset}"
    log "  Pool Dir:   ${POOL_DIR:-auto}"
    log "  CNCLI:      ${CNCLI_ENABLED}"
    log "  Mithril:    ${MITHRIL_SIGNER}"
    log "  PoolTool:   ${PT_API_KEY:+configured}${PT_API_KEY:-not set}"
fi
if [ -n "${MEMPOOL_OVERRIDE}" ]; then
    log "  Mempool:    ${MEMPOOL_OVERRIDE}"
fi
log "============================================"

log "cardano-node $(cardano-node --version 2>/dev/null | head -1)"

# 1. Install runtime deps (e2fsprogs, sudo) if missing
install_runtime_deps

# 2. Setup network configs
setup_network_configs

# 2a. Swap cardano-cli for APEX networks (requires CLI 9.4.1.0)
if [ "${NETWORK}" = "afpm" ] || [ "${NETWORK}" = "afpt" ]; then
    if [ -x /usr/local/bin/cardano-cli-apex ]; then
        log "ApexFusion: activating cardano-cli-apex (9.4.1.0) as default CLI"
        ln -sf /usr/local/bin/cardano-cli-apex /usr/local/bin/cardano-cli
    else
        warn "cardano-cli-apex not found — APEX tooling may not work correctly"
    fi
fi

# 3. Customise configs (bind 0.0.0.0, enable chattr)
customise_configs

# 4. Pre-startup sanity checks (stale socket cleanup + genesis hash verification)
pre_startup_sanity

# 5. Configure pool info in Guild scripts (BP mode)
configure_pool

# 6. DB Backup/Restore
handle_backup_restore

# 7. Mithril bootstrap (if enabled)
mithril_bootstrap

# 8. Build node command
NODE_CMD=$(build_node_cmd)
log "Starting: ${NODE_CMD}"

# 9. Launch cardano-node
eval ${NODE_CMD} &
NODE_PID=$!
log "cardano-node started (PID ${NODE_PID})"

# 10. Start CNCLI background processes (BP mode)
start_cncli_processes

# 11. Start mithril-signer if enabled (BP mode)
start_mithril_signer

# 12. Wait for node process
wait ${NODE_PID}
EXIT_CODE=$?
log "cardano-node exited with code ${EXIT_CODE}"
exit ${EXIT_CODE}
