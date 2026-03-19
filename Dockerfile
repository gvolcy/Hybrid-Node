# ============================================================================
# Hybrid-Node Dockerfile
# Combines Blink Labs source-built binaries with Guild Operators tooling
# https://github.com/volcyada/Hybrid-Node
# ============================================================================

# ----- Build Arguments -----
ARG NODE_VERSION=10.6.2
ARG CLI_VERSION=10.14.0.0
ARG GHC_VERSION=9.6.6
ARG CABAL_VERSION=3.12.1.0
ARG HASKELL_IMAGE_TAG=9.6.6-3.12.1.0-3

# ============================================================================
# Stage 1: Build cardano-node and cardano-cli from source (Blink Labs approach)
# ============================================================================
FROM ghcr.io/blinklabs-io/haskell:${HASKELL_IMAGE_TAG} AS build

ARG NODE_VERSION
ARG CLI_VERSION

# Build cardano-node
RUN echo "Building cardano-node ${NODE_VERSION}..." && \
    git clone --depth 1 --branch ${NODE_VERSION} \
      https://github.com/IntersectMBO/cardano-node.git /build/cardano-node && \
    cd /build/cardano-node && \
    echo "package cardano-crypto-praos"   >  cabal.project.local && \
    echo "  flags: -external-libsodium-vrf" >> cabal.project.local && \
    cabal update && \
    cabal build cardano-node cardano-cli && \
    # Copy built binaries to staging area
    mkdir -p /build/bin && \
    cp $(cabal list-bin cardano-node) /build/bin/ && \
    cp $(cabal list-bin cardano-cli)  /build/bin/ && \
    # Strip debug symbols
    strip /build/bin/cardano-node && \
    strip /build/bin/cardano-cli && \
    echo "Build complete: cardano-node $(./build/bin/cardano-node --version | head -1)"

# ============================================================================
# Stage 2: Download pre-built companion tools (Blink Labs releases)
# ============================================================================
FROM debian:bookworm-slim AS tools

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Map Docker arch to tool arch
RUN case "${TARGETARCH}" in \
      amd64) echo "x86_64" > /tmp/arch ;; \
      arm64) echo "aarch64" > /tmp/arch ;; \
      *)     echo "unsupported" > /tmp/arch ;; \
    esac

# Download mithril-client
ARG MITHRIL_CLIENT_VERSION=0.12.38
RUN ARCH=$(cat /tmp/arch) && \
    curl -sL "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_CLIENT_VERSION}/mithril-client-${MITHRIL_CLIENT_VERSION}-linux-${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin/ || \
    echo "WARN: mithril-client download failed, will try alternative" && \
    chmod +x /usr/local/bin/mithril-client 2>/dev/null || true

# Download mithril-signer
ARG MITHRIL_SIGNER_VERSION=0.3.7
RUN ARCH=$(cat /tmp/arch) && \
    curl -sL "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_SIGNER_VERSION}/mithril-signer-${MITHRIL_SIGNER_VERSION}-linux-${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin/ || \
    echo "WARN: mithril-signer download failed" && \
    chmod +x /usr/local/bin/mithril-signer 2>/dev/null || true

# Download nview
ARG NVIEW_VERSION=0.13.0
RUN ARCH=$(cat /tmp/arch) && \
    curl -sL "https://github.com/blinklabs-io/nview/releases/download/v${NVIEW_VERSION}/nview_${NVIEW_VERSION}_linux_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin/ nview && \
    chmod +x /usr/local/bin/nview

# Download txtop
ARG TXTOP_VERSION=0.14.0
RUN ARCH=$(cat /tmp/arch) && \
    curl -sL "https://github.com/blinklabs-io/txtop/releases/download/v${TXTOP_VERSION}/txtop_${TXTOP_VERSION}_linux_${ARCH}.tar.gz" \
    | tar xz -C /usr/local/bin/ txtop && \
    chmod +x /usr/local/bin/txtop

# Download cncli
ARG CNCLI_VERSION=6.4.1
RUN ARCH=$(cat /tmp/arch) && \
    if [ "${ARCH}" = "x86_64" ]; then \
      curl -sL "https://github.com/cardano-community/cncli/releases/download/v${CNCLI_VERSION}/cncli-${CNCLI_VERSION}-${ARCH}-unknown-linux-gnu.tar.gz" \
      | tar xz -C /usr/local/bin/ && \
      chmod +x /usr/local/bin/cncli; \
    else \
      echo "cncli not available for ${ARCH}, skipping"; \
    fi

# ============================================================================
# Stage 3: Final image — Guild Operators structure + all binaries
# ============================================================================
FROM debian:bookworm-slim AS final

LABEL maintainer="VolcyAda <https://github.com/volcyada>"
LABEL org.opencontainers.image.title="Hybrid-Node"
LABEL org.opencontainers.image.description="Hybrid Cardano node: Blink Labs source build + Guild Operators tooling"
LABEL org.opencontainers.image.source="https://github.com/volcyada/Hybrid-Node"
LABEL org.opencontainers.image.licenses="MIT"

# Runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash bc curl wget jq procps net-tools iproute2 \
    tcptraceroute sqlite3 tmux ncurses-bin \
    libsodium23 libsecp256k1-1 liblzma5 libz3-4 \
    libgmp10 libnuma1 libffi8 libtinfo6 \
    ca-certificates dnsutils \
    && rm -rf /var/lib/apt/lists/*

# Create guild user and directory structure (Guild Operators convention)
RUN useradd -m -d /home/guild -s /bin/bash guild && \
    mkdir -p /opt/cardano/cnode/{db,logs,priv,scripts,files,guild-db} && \
    mkdir -p /opt/cardano/cnode/priv/pool && \
    chown -R guild:guild /opt/cardano

# Copy source-built binaries from Stage 1
COPY --from=build /build/bin/cardano-node /usr/local/bin/
COPY --from=build /build/bin/cardano-cli  /usr/local/bin/

# Copy companion tools from Stage 2
COPY --from=tools /usr/local/bin/mithril-client  /usr/local/bin/
COPY --from=tools /usr/local/bin/mithril-signer  /usr/local/bin/
COPY --from=tools /usr/local/bin/nview            /usr/local/bin/
COPY --from=tools /usr/local/bin/txtop            /usr/local/bin/
COPY --from=tools /usr/local/bin/cncli            /usr/local/bin/

# Install Guild Operators scripts (CNTools, gLiveView, etc.)
USER guild
WORKDIR /opt/cardano/cnode

# Deploy Guild scripts — use guild-deploy.sh from Guild Operators
# -s d = Download scripts only (no node binary)
# -n = Non-interactive
# -p /opt/cardano/cnode = Install path
RUN curl -sS -o /tmp/guild-deploy.sh \
      https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh && \
    chmod +x /tmp/guild-deploy.sh && \
    SKIP_UPDATE=Y CNODE_HOME=/opt/cardano/cnode \
    bash /tmp/guild-deploy.sh -b master -n -s dlp && \
    rm -f /tmp/guild-deploy.sh

# Download mithril-related guild scripts
RUN for script in mithril-client.sh mithril-signer.sh mithril-relay.sh; do \
      curl -sS -o /opt/cardano/cnode/scripts/${script} \
        "https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/${script}" 2>/dev/null && \
      chmod +x /opt/cardano/cnode/scripts/${script} 2>/dev/null || true; \
    done

# Switch back to root for entrypoint setup
USER root

# Copy entrypoint and configs
COPY bin/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Copy network config override files
COPY configs/ /opt/cardano/cnode/hybrid-configs/
RUN chown -R guild:guild /opt/cardano/cnode/hybrid-configs/

# Environment defaults
ENV NETWORK=mainnet \
    NODE_MODE=relay \
    NODE_PORT=6000 \
    CNODE_HOME=/opt/cardano/cnode \
    CARDANO_NODE_SOCKET_PATH=/opt/cardano/cnode/db/node.socket \
    UPDATE_CHECK=N \
    MITHRIL_DOWNLOAD=N \
    MITHRIL_SIGNER=N \
    RTS_OPTS="-N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return" \
    PATH="/opt/cardano/cnode/scripts:/usr/local/bin:${PATH}"

# Expose default node port and Prometheus metrics
EXPOSE 6000 12798

# Volumes for persistent data
VOLUME ["/opt/cardano/cnode/db", "/opt/cardano/cnode/priv", "/opt/cardano/cnode/logs"]

# Healthcheck using cardano-cli
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD cardano-cli query tip --socket-path ${CARDANO_NODE_SOCKET_PATH} 2>/dev/null | jq -e '.syncProgress == "100.00"' > /dev/null 2>&1 || \
        (cardano-cli query tip --socket-path ${CARDANO_NODE_SOCKET_PATH} 2>/dev/null | jq -e '.syncProgress' > /dev/null 2>&1 && exit 0) || exit 1

USER guild
WORKDIR /opt/cardano/cnode

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
