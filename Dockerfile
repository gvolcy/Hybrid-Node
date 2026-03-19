# ============================================================================
# Hybrid-Node Dockerfile
# Combines Blink Labs source-built binaries with Guild Operators tooling
# https://github.com/volcyada/Hybrid-Node
# ============================================================================

# ----- Build Arguments -----
ARG NODE_VERSION=10.6.2
ARG GHC_VERSION=9.6.6
ARG CABAL_VERSION=3.12.1.0
ARG HASKELL_IMAGE_TAG=9.6.6-3.12.1.0-3

# ============================================================================
# Stage 1: Build cardano-node and cardano-cli from source (Blink Labs approach)
# ============================================================================
FROM ghcr.io/blinklabs-io/haskell:${HASKELL_IMAGE_TAG} AS build

ARG NODE_VERSION

RUN echo "Building cardano-node ${NODE_VERSION}..." && \
    git clone --depth 1 --branch ${NODE_VERSION} \
      https://github.com/IntersectMBO/cardano-node.git /build/cardano-node && \
    cd /build/cardano-node && \
    echo "package cardano-crypto-praos"     >  cabal.project.local && \
    echo "  flags: -external-libsodium-vrf" >> cabal.project.local && \
    cabal update && \
    cabal build cardano-node cardano-cli && \
    mkdir -p /build/bin && \
    cp $(cabal list-bin cardano-node) /build/bin/ && \
    cp $(cabal list-bin cardano-cli)  /build/bin/ && \
    strip /build/bin/cardano-node && \
    strip /build/bin/cardano-cli

# ============================================================================
# Stage 2: Download pre-built companion tools
# ============================================================================
FROM debian:bookworm-slim AS tools

ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# --- Mithril (IOG .deb packages from stable release) ---
ARG MITHRIL_RELEASE=2603.1
ARG MITHRIL_CLIENT_VERSION=0.12.38
ARG MITHRIL_SIGNER_VERSION=0.3.7
ARG MITHRIL_BUILD_HASH=567a8e8

RUN ARCH="${TARGETARCH}" && \
    echo "Installing mithril-client ${MITHRIL_CLIENT_VERSION} (${ARCH})..." && \
    curl -sL -o /tmp/mithril-client.deb \
      "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_RELEASE}/mithril-client-cli_${MITHRIL_CLIENT_VERSION}%2B${MITHRIL_BUILD_HASH}-1_${ARCH}.deb" && \
    dpkg -i /tmp/mithril-client.deb && \
    rm -f /tmp/mithril-client.deb && \
    echo "Installing mithril-signer ${MITHRIL_SIGNER_VERSION} (${ARCH})..." && \
    curl -sL -o /tmp/mithril-signer.deb \
      "https://github.com/input-output-hk/mithril/releases/download/${MITHRIL_RELEASE}/mithril-signer_${MITHRIL_SIGNER_VERSION}%2B${MITHRIL_BUILD_HASH}-1_${ARCH}.deb" && \
    dpkg -i /tmp/mithril-signer.deb && \
    rm -f /tmp/mithril-signer.deb

# --- nview (Blink Labs — raw binary) ---
ARG NVIEW_VERSION=0.13.0
RUN ARCH="${TARGETARCH}" && \
    curl -sL -o /usr/local/bin/nview \
      "https://github.com/blinklabs-io/nview/releases/download/v${NVIEW_VERSION}/nview-v${NVIEW_VERSION}-linux-${ARCH}" && \
    chmod +x /usr/local/bin/nview

# --- txtop (Blink Labs — raw binary) ---
ARG TXTOP_VERSION=0.14.0
RUN ARCH="${TARGETARCH}" && \
    curl -sL -o /usr/local/bin/txtop \
      "https://github.com/blinklabs-io/txtop/releases/download/v${TXTOP_VERSION}/txtop-v${TXTOP_VERSION}-linux-${ARCH}" && \
    chmod +x /usr/local/bin/txtop

# --- cncli (cardano-community — tarball, amd64 only) ---
ARG CNCLI_VERSION=6.7.0
RUN ARCH="${TARGETARCH}" && \
    if [ "${ARCH}" = "amd64" ]; then \
      curl -sL "https://github.com/cardano-community/cncli/releases/download/v${CNCLI_VERSION}/cncli-${CNCLI_VERSION}-ubuntu22-x86_64-unknown-linux-gnu.tar.gz" \
      | tar xz -C /usr/local/bin/ && \
      chmod +x /usr/local/bin/cncli; \
    else \
      echo "cncli not available for ${ARCH}, skipping"; \
      touch /usr/local/bin/cncli; \
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

ENV CNODE_HOME=/opt/cardano/cnode
# SUDO=N tells guild-deploy.sh to skip sudo wrapper (required for Docker builds)
ENV SUDO=N

# Runtime dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash bc curl wget jq procps net-tools iproute2 \
    tcptraceroute sqlite3 tmux ncurses-bin \
    libsodium23 libsecp256k1-1 liblzma5 libz3-4 \
    libgmp10 libnuma1 libffi8 libtinfo6 \
    ca-certificates dnsutils \
    && rm -rf /var/lib/apt/lists/*

# Create guild user (UID 1000 for K3s fsGroup compatibility)
RUN useradd -m -d /home/guild -s /bin/bash -u 1000 guild && \
    mkdir -p ${CNODE_HOME}/{db,logs,priv,scripts,files,guild-db,sockets} && \
    mkdir -p ${CNODE_HOME}/priv/pool && \
    mkdir -p /root/.local/bin && \
    chown -R guild:guild /opt/cardano

# Copy source-built binaries from Stage 1
COPY --from=build /build/bin/cardano-node /usr/local/bin/
COPY --from=build /build/bin/cardano-cli  /usr/local/bin/

# Copy shared libraries from build stage that are newer than Debian bookworm
COPY --from=build /usr/local/lib/libsecp256k1.so.2     /usr/local/lib/
COPY --from=build /usr/local/lib/libsecp256k1.so.2.0.2 /usr/local/lib/
RUN ldconfig

# Copy companion tools from Stage 2
# Note: mithril debs install to /usr/bin, others to /usr/local/bin
COPY --from=tools /usr/bin/mithril-client  /usr/local/bin/
COPY --from=tools /usr/bin/mithril-signer  /usr/local/bin/
COPY --from=tools /usr/local/bin/nview     /usr/local/bin/
COPY --from=tools /usr/local/bin/txtop     /usr/local/bin/
COPY --from=tools /usr/local/bin/cncli     /usr/local/bin/

# ---- Install Guild Operators scripts (run as root with SUDO=N) ----
# Pass 1: Download helper scripts and platform configs
ARG G_ACCOUNT=cardano-community
ARG GUILD_DEPLOY_BRANCH=master

RUN apt-get update && \
    curl -sS -o /tmp/guild-deploy.sh \
      https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/guild-deploy.sh && \
    chmod +x /tmp/guild-deploy.sh && \
    SUDO=N SKIP_UPDATE=Y SKIP_DBSYNC_DOWNLOAD=Y CNODE_HOME=${CNODE_HOME} \
    bash /tmp/guild-deploy.sh -b ${GUILD_DEPLOY_BRANCH} -s p && \
    apt-get -y purge && apt-get -y clean && apt-get -y autoremove && \
    rm -rf /var/lib/apt/lists/*

# Pass 2: Download scripts, configs, mithril helpers, wallet, other tools
RUN SUDO=N SKIP_UPDATE=Y SKIP_DBSYNC_DOWNLOAD=Y CNODE_HOME=${CNODE_HOME} \
    bash /tmp/guild-deploy.sh -b ${GUILD_DEPLOY_BRANCH} -s dcmowx && \
    rm -f /tmp/guild-deploy.sh && \
    chown -R guild:guild ${CNODE_HOME} && \
    mv /root/.local/bin /home/guild/.local/ 2>/dev/null || true && \
    chown -R guild:guild /home/guild/

# Download configs for all supported networks
RUN bash -c 'networks=(guild mainnet preprod preview); \
    files=({alonzo,byron,conway,shelley}-genesis.json config.json topology.json); \
    for network in "${networks[@]}"; do \
        mkdir -pv ${CNODE_HOME}/files/${network} && \
        for file in "${files[@]}"; do \
            curl -s -o ${CNODE_HOME}/files/${network}/${file} \
              https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/${file} 2>/dev/null || true; \
        done; \
    done' && chown -R guild:guild /opt/cardano

# Download additional mithril guild scripts
RUN for script in mithril-client.sh mithril-signer.sh mithril-relay.sh; do \
      curl -sS -o ${CNODE_HOME}/scripts/${script} \
        "https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/${script}" 2>/dev/null && \
      chmod +x ${CNODE_HOME}/scripts/${script} 2>/dev/null || true; \
    done && chown -R guild:guild ${CNODE_HOME}/scripts/

# Copy entrypoint and config overrides
COPY bin/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

COPY configs/ ${CNODE_HOME}/hybrid-configs/
RUN chown -R guild:guild ${CNODE_HOME}/hybrid-configs/

# Environment defaults
ENV NETWORK=mainnet \
    NODE_MODE=relay \
    NODE_PORT=6000 \
    CARDANO_NODE_SOCKET_PATH=${CNODE_HOME}/db/node.socket \
    UPDATE_CHECK=N \
    MITHRIL_DOWNLOAD=N \
    MITHRIL_SIGNER=N \
    RTS_OPTS="-N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return" \
    PATH="${CNODE_HOME}/scripts:/usr/local/bin:${PATH}"

# Expose node port and Prometheus metrics
EXPOSE 6000 12798

# Volumes for persistent data
VOLUME ["${CNODE_HOME}/db", "${CNODE_HOME}/priv", "${CNODE_HOME}/logs"]

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=300s --retries=3 \
    CMD cardano-cli query tip --socket-path ${CARDANO_NODE_SOCKET_PATH} 2>/dev/null \
        | jq -e '.syncProgress' > /dev/null 2>&1 || exit 1

USER guild
WORKDIR ${CNODE_HOME}

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
