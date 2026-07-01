#!/usr/bin/env bash
# ============================================================================
# Hybrid-Node Entrypoint
# Handles: network config, mithril bootstrap, BP/relay mode, cncli processes,
#          PoolTool.io reporting, signal handling, graceful shutdown
# ============================================================================
set -eo pipefail

# ----- Colors for output -----
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
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
# RTS GC tuning. Override per-deployment via the RTS_OPTS env var (no image rebuild needed).
# The default profile favors LOW MEMORY (relay-friendly) over raw throughput:
#   -A16m / -n4m : smaller chunked nursery -> lower baseline RSS, still scales across N cores
#   -F1.5        : grow old-gen heap to 1.5x live data (GHC default 2.0) -> lower peak RSS
#   -I0.3 -Iw600 : re-enable idle GC (at most once / 600s) so freed memory is reclaimed when quiet
#   --disable-delayed-os-memory-return : hand freed pages straight back to the OS
#   -qg -qb      : sequential GC (lower transient memory than parallel GC)
# Throughput-critical block producers can opt back into the old profile by setting RTS_OPTS env:
#   "-N${CPU_CORES} -I0 -A64m -qg -qb --disable-delayed-os-memory-return"
: "${RTS_OPTS:=-N${CPU_CORES} -A16m -n4m -F1.5 -I0.3 -Iw600 -qg -qb --disable-delayed-os-memory-return}"
: "${ENABLE_BACKUP:=N}"
: "${ENABLE_RESTORE:=N}"
: "${CNCLI_ENABLED:=N}"
: "${CARDANO_BLOCK_PRODUCER:=false}"
: "${START_AS_NON_PRODUCING:=false}"
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

    # Signal cardano-node FIRST so its (slowest) clean shutdown starts
    # immediately and runs concurrently with helper teardown. This also means a
    # misbehaving helper (e.g. a mithril-signer that ignores SIGTERM) can never
    # block the node from receiving its shutdown signal.
    if [ -n "${NODE_PID}" ] && kill -0 "${NODE_PID}" 2>/dev/null; then
        log "Stopping cardano-node (PID ${NODE_PID}) with SIGINT..."
        kill -SIGINT "${NODE_PID}" 2>/dev/null
    fi

    # Stop cncli background processes
    for pid in "${CNCLI_PIDS[@]}"; do
        if kill -0 "${pid}" 2>/dev/null; then
            log "Stopping cncli process (PID ${pid})..."
            kill -SIGTERM "${pid}" 2>/dev/null || true
        fi
    done

    # Stop mithril-signer (bounded wait so it can't stall shutdown)
    if [ -n "${SIGNER_PID}" ] && kill -0 "${SIGNER_PID}" 2>/dev/null; then
        log "Stopping mithril-signer (PID ${SIGNER_PID})..."
        kill -SIGTERM "${SIGNER_PID}" 2>/dev/null
        ( sleep 15; kill -SIGKILL "${SIGNER_PID}" 2>/dev/null ) &
        local sig_wd=$!
        wait "${SIGNER_PID}" 2>/dev/null || true
        kill "${sig_wd}" 2>/dev/null || true
    fi

    # Wait for cardano-node's clean shutdown (it was signalled above).
    if [ -n "${NODE_PID}" ] && kill -0 "${NODE_PID}" 2>/dev/null; then
        # Wait for a clean shutdown, up to 540s (must stay under the pod's
        # terminationGracePeriodSeconds=600 so the node exits on its own rather
        # than being SIGKILLed, which would force a full DB revalidation).
        #
        # Use `wait` (not a `kill -0` poll): `wait` blocks until the child
        # exits AND reaps it. A `kill -0` poll would keep succeeding on a
        # zombie (exited-but-unreaped) process and burn the full timeout even
        # on a clean, fast shutdown. A background watchdog enforces the cap.
        local timeout=540
        ( sleep "${timeout}"; kill -SIGKILL "${NODE_PID}" 2>/dev/null ) &
        local watchdog=$!

        wait "${NODE_PID}" 2>/dev/null

        if kill -0 "${watchdog}" 2>/dev/null; then
            # Node exited before the watchdog fired -> clean shutdown.
            kill "${watchdog}" 2>/dev/null || true
            wait "${watchdog}" 2>/dev/null || true
            log "cardano-node stopped gracefully"
        else
            warn "Node didn't stop within ${timeout}s, was SIGKILLed by watchdog"
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
        if ! { apt-get update -qq 2>/dev/null && \
               apt-get install -y --no-install-recommends e2fsprogs sudo >/dev/null 2>&1; }; then
            warn "Could not install e2fsprogs/sudo (running as non-root?)"
        fi

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
        local byron_cfg
        byron_cfg=$(jq -r '.ByronGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${byron_hash}" ] && [ "${byron_hash}" != "${byron_cfg}" ]; then
            warn "Byron genesis hash mismatch: config=${byron_cfg:0:16}... actual=${byron_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${shelley_genesis}" ]; then
        shelley_hash=$(cardano-cli hash genesis-file --genesis "${shelley_genesis}" 2>/dev/null || true)
        local shelley_cfg
        shelley_cfg=$(jq -r '.ShelleyGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${shelley_hash}" ] && [ "${shelley_hash}" != "${shelley_cfg}" ]; then
            warn "Shelley genesis hash mismatch: config=${shelley_cfg:0:16}... actual=${shelley_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${alonzo_genesis}" ]; then
        alonzo_hash=$(cardano-cli hash genesis-file --genesis "${alonzo_genesis}" 2>/dev/null || true)
        local alonzo_cfg
        alonzo_cfg=$(jq -r '.AlonzoGenesisHash // empty' "${config_file}" 2>/dev/null)
        if [ -n "${alonzo_hash}" ] && [ "${alonzo_hash}" != "${alonzo_cfg}" ]; then
            warn "Alonzo genesis hash mismatch: config=${alonzo_cfg:0:16}... actual=${alonzo_hash:0:16}..."
            needs_fix=true
        fi
    fi

    if [ -f "${conway_genesis}" ]; then
        conway_hash=$(cardano-cli hash genesis-file --genesis "${conway_genesis}" 2>/dev/null || true)
        local conway_cfg
        conway_cfg=$(jq -r '.ConwayGenesisHash // empty' "${config_file}" 2>/dev/null)
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

        # BP nodes: Harden P2P peer settings
        # BPs must ONLY connect to their own relays — never discover or accept
        # public peers.  PeerSharing lets peers exchange addresses, causing the
        # BP to connect outbound to random internet peers.  High target numbers
        # amplify the problem by making the node actively fill those slots.
        if [ "${NODE_MODE}" = "bp" ]; then
            log "BP mode: Hardening P2P peer settings (PeerSharing=disabled, targets=relay-count)"
            local relay_count
            relay_count=$(jq -r "[.localRoots[]?.accessPoints // [] | length] | add // 3" \
                "${CONFIG_DIR}/topology.json" 2>/dev/null || echo 3)
            jq --argjson rc "${relay_count}" '
                .PeerSharing = false |
                .TargetNumberOfActivePeers = $rc |
                .TargetNumberOfEstablishedPeers = $rc |
                .TargetNumberOfKnownPeers = $rc |
                .TargetNumberOfRootPeers = $rc
            ' "${main_config}" > "${main_config}.tmp" && \
                mv "${main_config}.tmp" "${main_config}"
        fi

        # Relay mode: enable PeerSharing so relays can discover and share peers
        # BPs already have PeerSharing=false set above
        if [ "${NODE_MODE}" != "bp" ]; then
            local peer_sharing
            peer_sharing=$(jq -r '.PeerSharing // empty' "${main_config}" 2>/dev/null)
            if [ "${peer_sharing}" != "true" ]; then
                log "Relay mode: Enabling PeerSharing for better peer discovery"
                jq '.PeerSharing = true' "${main_config}" > "${main_config}.tmp" && \
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
        if [ "${trace_dispatcher}" = "true" ] || [ "${trace_dispatcher}" = "missing" ] || [ "${has_legacy_traces}" = "no" ]; then
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
        if grep -qi ENABLE_CHATTR "${CNODE_HOME}/scripts/cntools.sh" 2>/dev/null; then
            sed -i 's/#ENABLE_CHATTR=false/ENABLE_CHATTR=true/g' "${CNODE_HOME}/scripts/cntools.sh" 2>/dev/null || true
        fi
    fi

    # Patch CNTools getBalanceKoios for the Koios CSV column-order regression.
    # Upstream requests address_utxos as text/csv and parses positionally; the
    # public Koios API now returns columns in schema order (asset_list 2nd),
    # so the JSON asset_list blob (full of commas) shreds the positional read
    # and `$(( ... + _value ))` aborts, crashing "Show wallet" for any wallet
    # holding native tokens. Re-parse the response as JSON via jq instead.
    patch_cntools_koios_balance
}

# Replace CNTools getBalanceKoios with a JSON/jq parser (column-order safe).
patch_cntools_koios_balance() {
    local lib="${CNODE_HOME}/scripts/cntools.library"
    [ -f "${lib}" ] || return 0
    grep -q 'HYBRIDNODE_KOIOS_BALANCE_PATCH' "${lib}" 2>/dev/null && return 0
    grep -q '^getBalanceKoios() {' "${lib}" 2>/dev/null || return 0

    local patch_file="/tmp/.cntools-getBalanceKoios.patch"
    cat > "${patch_file}" <<'PATCH_EOF'
getBalanceKoios() {
  # HYBRIDNODE_KOIOS_BALANCE_PATCH: parse Koios address_utxos as JSON (column-order safe)
  declare -gA utxos=(); declare -gA utxos_cnt=(); declare -gA assets=(); declare -gA tx_in_arr=(); declare -gA asset_name_maxlen_arr=(); declare -gA asset_amount_maxlen_arr=()

  if [[ -n ${KOIOS_API} && -n ${addr_list+x} ]]; then
    printf -v addr_list_joined '\"%s\",' "${addr_list[@]}"
    [[ $1 != false ]] && extended=true || extended=false
    HEADERS=("${KOIOS_API_HEADERS[@]}" -H "Content-Type: application/json" -H "accept: application/json")
    println ACTION "curl -sSL -f -X POST ${HEADERS[*]} -d '{\"_addresses\":[${addr_list_joined%,}],\"_extended\":${extended}}' ${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list"
    ! address_utxo_list=$(curl -sSL -f -X POST "${HEADERS[@]}" -d '{"_addresses":['${addr_list_joined%,}'],"_extended":'${extended}'}' "${KOIOS_API}/address_utxos?select=address,tx_hash,tx_index,value,asset_list" 2>&1) && println "ERROR" "\n${FG_RED}KOIOS_API ERROR${NC}: ${address_utxo_list}\n" && return 1
    [[ -z ${address_utxo_list} || ${address_utxo_list} = '[]' ]] && return
    while IFS=$'\t' read -r _address _tx_hash _tx_index _value _asset_list_b64; do
      [[ -z ${_address} ]] && continue
      index_prefix="${_address},"
      assets["${index_prefix}lovelace"]=$(( ${assets["${index_prefix}lovelace"]:-0} + _value ))
      utxos["${index_prefix}${_tx_hash}#${_tx_index}. ADA"]=${_value}
      utxos_cnt["${_address}"]=$(( ${utxos_cnt["${_address}"]:-0} + 1 ))
      tx_in_arr["${_address}"]="${tx_in_arr["${_address}"]} --tx-in ${_tx_hash}#${_tx_index}"
      if [[ $1 != false ]]; then
        _asset_list=$(base64 -d <<< "${_asset_list_b64}" 2>/dev/null)
        [[ -z ${_asset_list} || ${_asset_list} = 'null' ]] && continue
        while IFS=$'\t' read -r _policy_id _asset_name _quantity; do
          [[ -z ${_policy_id} ]] && continue
          tname="$(hexToAscii ${_asset_name})"
          tname="${tname//[![:print:]]/}"
          [[ ${#tname} -gt ${asset_name_maxlen_arr["${_address}"]:-5} ]] && asset_name_maxlen_arr["${_address}"]=${#tname}
          asset_amount_fmt="$(formatAsset ${_quantity})"
          [[ ${#asset_amount_fmt} -gt ${asset_amount_maxlen_arr["${_address}"]:-12} ]] && asset_amount_maxlen_arr["${_address}"]=${#asset_amount_fmt}
          assets["${index_prefix}${_policy_id}.${_asset_name}"]=$(( ${assets["${index_prefix}${_policy_id}.${_asset_name}"]:-0} + _quantity ))
          utxos["${index_prefix}${_tx_hash}#${_tx_index}.${_policy_id}.${_asset_name}"]=${_quantity}
        done < <( jq -cr '.[]? | [.policy_id, .asset_name, .quantity] | @tsv' <<< "${_asset_list}" )
      fi
    done < <( jq -r '.[] | [.address, .tx_hash, .tx_index, .value, ((.asset_list // []) | @json | @base64)] | @tsv' <<< "${address_utxo_list}" )
  fi
}
PATCH_EOF

    cp -a "${lib}" "${lib}.bak-koiosbal" 2>/dev/null || true
    if awk -v fn="${patch_file}" '
        BEGIN { while ((getline line < fn) > 0) repl = repl line "\n" }
        /^getBalanceKoios\(\) \{/ { inblock=1; printf "%s", repl; next }
        inblock && /^}/ { inblock=0; next }
        inblock { next }
        { print }
    ' "${lib}" > "${lib}.new" 2>/dev/null && bash -n "${lib}.new" 2>/dev/null; then
        mv "${lib}.new" "${lib}"
        log "Patched CNTools getBalanceKoios (Koios JSON parser)"
    else
        rm -f "${lib}.new"
        log "WARN: CNTools getBalanceKoios patch skipped (splice/syntax check failed)"
    fi
    rm -f "${patch_file}"
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
            # Also update if already set to a different value (e.g. PV-persisted env file)
            sed -i "s|^CNODE_PORT=.*|CNODE_PORT=${CNODE_PORT}|g" "${env_file}" 2>/dev/null || true
        fi
    fi

    # Configure cncli.sh with pool information
    local cncli_script="${CNODE_HOME}/scripts/cncli.sh"
    if [ -f "${cncli_script}" ]; then
        if [ -n "${POOL_ID}" ]; then
            sed -i "s|POOL_ID=\".*\"|POOL_ID=\"${POOL_ID}\"|g" "${cncli_script}" 2>/dev/null || true
        fi
        if [ -n "${POOL_TICKER}" ]; then
            sed -i "s|POOL_TICKER=\".*\"|POOL_TICKER=\"${POOL_TICKER}\"|g" "${cncli_script}" 2>/dev/null || true
        fi
        if [ -n "${PT_API_KEY}" ]; then
            sed -i "s|PT_API_KEY=\".*\"|PT_API_KEY=\"${PT_API_KEY}\"|g" "${cncli_script}" 2>/dev/null || true
        fi
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

    local dbsize
    dbsize=$(du -s "${DB_DIR}" 2>/dev/null | awk '{print $1}')
    local bksize
    bksize=$(du -s "${backup_dir}" 2>/dev/null | awk '{print $1}')
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
        leios)   BASE_URL="https://book.play.dev.cardano.org/environments-pre/leios"
                 log "Ouroboros Leios — Musashi Dojo testnet (magic 164)" ;;
        *)       err "Unknown network: ${NETWORK}. Supported: mainnet, preview, preprod, guild, afpm, afpt, leios"; exit 1 ;;
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
    elif [ "${NETWORK}" = "leios" ]; then
        # Leios: guild-deploy seeds a Cardano *mainnet* topology (backbone peers),
        # which is wrong for Musashi Dojo. Always pull the Leios topology so the
        # node bootstraps from leios-node.play.dev.cardano.org and picks up the
        # peerSnapshotFile reference. (BP mode with CUSTOM_PEERS still overrides
        # this below via add_custom_peers.)
        log "Downloading ${NETWORK} topology.json (force refresh over guild default)..."
        curl -sS -o "${CONFIG_DIR}/topology.json" "${BASE_URL}/topology.json"
    elif [ ! -f "${CONFIG_DIR}/topology.json" ]; then
        log "Downloading ${NETWORK} topology.json..."
        curl -sS -o "${CONFIG_DIR}/topology.json" "${BASE_URL}/topology.json"
    fi

    # Download genesis files for the requested network (always refresh to ensure correct network)
    # Leios (Musashi Dojo) introduces a 5th era genesis: dijkstra-genesis.json
    local genesis_files="byron-genesis.json shelley-genesis.json alonzo-genesis.json conway-genesis.json"
    if [ "${NETWORK}" = "leios" ]; then
        genesis_files="${genesis_files} dijkstra-genesis.json"
    fi
    for genesis in ${genesis_files}; do
        log "Downloading ${genesis} for ${NETWORK}..."
        curl -sS -o "${CONFIG_DIR}/${genesis}" "${BASE_URL}/${genesis}" 2>/dev/null || \
            warn "Could not download ${genesis} (may not exist for this network)"
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

    # Leios (Musashi Dojo): topology.json references a peer snapshot file.
    # Fetch the file named by peerSnapshotFile (default peer-snapshot.json) so the
    # node doesn't fail on a missing reference.
    if [ "${NETWORK}" = "leios" ] && [ -f "${CONFIG_DIR}/topology.json" ]; then
        local snap_file
        snap_file=$(jq -r '.peerSnapshotFile // "peer-snapshot.json"' "${CONFIG_DIR}/topology.json" 2>/dev/null)
        if [ -n "${snap_file}" ] && [ "${snap_file}" != "null" ]; then
            log "Downloading ${snap_file} for leios..."
            curl -sS -o "${CONFIG_DIR}/${snap_file}" "${BASE_URL}/${snap_file}" 2>/dev/null || \
                warn "Could not download ${snap_file} (may not exist for this network)"
        fi
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

    if [ "${NODE_MODE}" = "bp" ]; then
        # BP mode: replace entire topology with ONLY the custom peers (locked-down)
        # BPs should connect exclusively to their own relays, never to public peers
        local num_peers=${#PEER_LIST[@]}
        local topology_json
        topology_json=$(jq -n --argjson peers "${peers_json}" --argjson n "${num_peers}" '{
            "bootstrapPeers": [],
            "localRoots": [{
                "accessPoints": $peers,
                "advertise": false,
                "trustable": true,
                "hotValency": $n,
                "warmValency": $n
            }],
            "publicRoots": [],
            "useLedgerAfterSlot": -1
        }')
        log "BP topology: set ${num_peers} exclusive relay peers (locked-down, no public roots)"
        echo "${topology_json}" > "${topology}"
    elif jq -e '.localRoots' "${topology}" > /dev/null 2>&1; then
        # Relay mode: append custom peers to existing topology
        # First check if custom peers are already present (avoid duplicates on restart)
        local first_addr first_port
        first_addr=$(echo "${peers_json}" | jq -r '.[0].address')
        first_port=$(echo "${peers_json}" | jq -r '.[0].port')
        if jq -e --arg a "${first_addr}" --argjson p "${first_port}" \
            '[.localRoots[].accessPoints[] | select(.address == $a and .port == $p)] | length > 0' \
            "${topology}" > /dev/null 2>&1; then
            log "Custom peers already present in topology, skipping duplicate append"
        else
            jq --argjson peers "${peers_json}" \
                '.localRoots += [{"accessPoints": $peers, "advertise": false, "trustable": false, "valency": ($peers | length)}]' \
                "${topology}" > "${topology}.tmp" && mv "${topology}.tmp" "${topology}"
            log "Added ${#PEER_LIST[@]} custom peers to P2P topology"
        fi
    fi
}

# ----- Mithril bootstrap -----
mithril_bootstrap() {
    if [ "${MITHRIL_DOWNLOAD}" != "Y" ] && [ "${MITHRIL_DOWNLOAD}" != "y" ]; then
        return
    fi

    if [ -d "${DB_DIR}/immutable" ] && [ "$(find "${DB_DIR}/immutable/" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)" -gt 0 ]; then
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
    GENESIS_VERIFICATION_KEY=$(curl -sS "${MITHRIL_AGGREGATOR}/epoch-settings" | jq -r '.protocol_parameters.genesis_verification_key // empty' 2>/dev/null || true)
    export GENESIS_VERIFICATION_KEY

    if [ -z "${GENESIS_VERIFICATION_KEY}" ]; then
        warn "Could not fetch Mithril genesis verification key, skipping"
        return
    fi


    # Fetch ancillary verification key (required by newer mithril-client versions)
    local ancillary_vkey=""
    ancillary_vkey=$(curl -sS "${MITHRIL_AGGREGATOR}/epoch-settings" | jq -r '.ancillary_verification_key // empty' 2>/dev/null || true)
    if [ -n "${ancillary_vkey}" ]; then
        export ANCILLARY_VERIFICATION_KEY="${ancillary_vkey}"
        log "Ancillary verification key loaded"
    fi

    log "Downloading latest snapshot..."
    mithril-client cardano-db download latest --download-dir "${DB_DIR}" \
        ${ancillary_vkey:+--include-ancillary} || {
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
        while ! timeout 10s cardano-cli query tip --socket-path "${CARDANO_NODE_SOCKET_PATH}" "${NETWORK_FLAG}" >/dev/null 2>&1; do
            sleep 15
        done
        log "  [mithril] Node responding to queries ✓"

        # Wait for reasonable sync progress (>90%)
        while true; do
            local sync
            sync=$(timeout 10s cardano-cli query tip --socket-path "${CARDANO_NODE_SOCKET_PATH}" "${NETWORK_FLAG}" 2>/dev/null | jq -r '.syncProgress // "0"' | sed 's/%//' || echo "0")
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

        # Wait for cardano-node to actually open the EKG port.
        # The Guild cncli.sh script uses `ss -lnpt` to verify the node PID is
        # listening on the EKG port.  If we start cncli.sh before the port is
        # open, it caches a stale PID and loops forever with:
        #   "ERROR: You specified <port> as your EKG port, but it looks like
        #    the cardano-node (PID: <stale>) is not listening on this port."
        # A fixed sleep is not reliable — wait until EKG is actually reachable.
        local ekg_wait_host="${EKG_HOST}"
        [ "${ekg_wait_host}" = "0.0.0.0" ] && ekg_wait_host="127.0.0.1"
        local ekg_wait=0
        log "  [cncli] Waiting for EKG port ${ekg_wait_host}:${EKG_PORT}..."
        while ! curl -sf -o /dev/null -m 2 "http://${ekg_wait_host}:${EKG_PORT}/" 2>/dev/null; do
            sleep 5
            ekg_wait=$((ekg_wait + 5))
            if [ ${ekg_wait} -ge 300 ]; then
                warn "  [cncli] EKG port not available after 300s, starting cncli anyway"
                break
            fi
        done
        log "  [cncli] EKG port ready after ${ekg_wait}s ✓"

        # Extra settle time to ensure ss sees the correct PID binding
        sleep 5
        mkdir -p "${GUILD_DB_DIR}" "${LOGS_DIR}"

        # Backup existing cncli database (guild layout: guild-db/cncli/cncli.db)
        if [ -f "${GUILD_DB_DIR}/cncli/cncli.db" ]; then
            log "  [cncli] Found existing cncli database - preserving"
            cp "${GUILD_DB_DIR}/cncli/cncli.db" "${GUILD_DB_DIR}/cncli/cncli.db.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        fi

        # Start PoolTool.io sendtip/sendslots if API key is available
        if [ -n "${PT_API_KEY}" ]; then
            log "  [cncli] Starting PoolTool.io sendtip..."
            "${CNODE_HOME}/scripts/cncli.sh" ptsendtip >> "${LOGS_DIR}/cncli-ptsendtip.log" 2>&1 &
            CNCLI_PIDS+=($!)
            "${CNODE_HOME}/scripts/cncli.sh" ptsendslots >> "${LOGS_DIR}/cncli-ptsendslots.log" 2>&1 &
            CNCLI_PIDS+=($!)
        else
            log "  [cncli] PT_API_KEY not set - skipping PoolTool.io (get key from pooltool.io)"
        fi

        # Start core CNCLI processes.
        # Log paths match what the cncli-keeper CronJob expects so that the
        # keeper can detect stuck processes and restart them properly.
        log "  [cncli] Starting sync, leaderlog, validate..."
        "${CNODE_HOME}/scripts/cncli.sh" sync > "${LOGS_DIR}/cncli-sync.log" 2>&1 &
        CNCLI_PIDS+=($!)
        "${CNODE_HOME}/scripts/cncli.sh" leaderlog > "${LOGS_DIR}/cncli-leaderlog.log" 2>&1 &
        CNCLI_PIDS+=($!)
        "${CNODE_HOME}/scripts/cncli.sh" validate > "${LOGS_DIR}/cncli-validate.log" 2>&1 &
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

        # Fix key file permissions — cardano-node refuses to start if VRF/KES
        # key files have group or other permissions.  K8s fsGroup adds group
        # bits to all mounted files, so we must strip them before every start.
        if [ -d "${priv_pool}" ]; then
            chmod 0600 "${priv_pool}"/*.skey "${priv_pool}"/op.cert "${priv_pool}"/node.cert "${priv_pool}"/opcert.cert 2>/dev/null || true
            log "BP mode: Key file permissions secured (0600)" >&2
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
        # Leios / common SPO layout: kes.skey, vrf.skey, op.cert
        elif [ -f "${priv_pool}/kes.skey" ] && [ -f "${priv_pool}/vrf.skey" ] && [ -f "${priv_pool}/op.cert" ]; then
            CMD="${CMD} --shelley-kes-key ${priv_pool}/kes.skey"
            CMD="${CMD} --shelley-vrf-key ${priv_pool}/vrf.skey"
            CMD="${CMD} --shelley-operational-certificate ${priv_pool}/op.cert"
            log "BP mode: KES keys loaded from ${priv_pool} (kes/op.cert naming)" >&2
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

        # Leios BLS signing key — after KES/VRF/op.cert; only when node supports it
        if [[ "${CMD}" == *"--shelley-kes-key"* ]] && [ -f "${priv_pool}/bls.skey" ]; then
            if cardano-node run --help 2>&1 | grep -q 'shelley-bls-key'; then
                chmod 0600 "${priv_pool}/bls.skey" 2>/dev/null || true
                CMD="${CMD} --shelley-bls-key ${priv_pool}/bls.skey"
                log "BP mode: BLS key loaded from ${priv_pool}/bls.skey" >&2
            else
                log "BP mode: bls.skey present; --shelley-bls-key not in this node build (Leios #776)" >&2
            fi
        fi

        # Dynamic block forging: start in non-producing mode, enable via SIGHUP
        # This allows zero-downtime KES key rotation and failover:
        #   Enable:  ensure key files exist, then: kill -SIGHUP <node-pid>
        #   Disable: rename/remove key files, then: kill -SIGHUP <node-pid>
        if [ "${START_AS_NON_PRODUCING}" = "true" ]; then
            CMD="${CMD} --start-as-non-producing-node"
            log "BP mode: Dynamic forging enabled (starting as non-producing, send SIGHUP to toggle)" >&2
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
        leios)   echo "--testnet-magic 164" ;;
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
    log "  DynForging: ${START_AS_NON_PRODUCING}"
fi
if [ -n "${MEMPOOL_OVERRIDE}" ]; then
    log "  Mempool:    ${MEMPOOL_OVERRIDE}"
fi
log "============================================"

log "cardano-node $(cardano-node --version 2>/dev/null | head -1)"
log "cardano-cli  $(cardano-cli --version 2>/dev/null | head -1)"

# 1. Install runtime deps (e2fsprogs, sudo) if missing
install_runtime_deps

# 2. Setup network configs
setup_network_configs

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
# IMPORTANT: use `exec` inside the backgrounded subshell so it REPLACES itself
# with cardano-node. Without `exec`, `eval "${NODE_CMD}" &` leaves an
# intermediate bash wrapper as the backgrounded process, so $! is the wrapper's
# PID (not cardano-node's). The shutdown trap would then send SIGINT to the
# wrapper bash, which never forwards it -> cardano-node never shuts down cleanly
# -> SIGKILL at grace expiry -> full immutable-DB revalidation on next start.
# With `exec`, $! is cardano-node's real PID and SIGINT reaches it directly.
eval "exec ${NODE_CMD}" &
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
