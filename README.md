# 🔀 Hybrid-Node

**A hybrid Cardano node Docker image combining the best of Guild Operators and Blink Labs for Kubernetes (K3s) deployments.**

[![Build and Push](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Why Hybrid?

| Source | What We Take | Why |
|--------|-------------|-----|
| **[Guild Operators](https://github.com/cardano-community/guild-operators)** | CNTools, gLiveView, cncli, guild-deploy scripts, mithril integration | Best operational tooling for block producers |
| **[Blink Labs](https://github.com/blinklabs-io/docker-cardano-node)** | Source-built `cardano-node`, `cardano-cli`, nview, txtop, mithril-client | Fast release cadence, multi-arch, from-source builds |
| **[CoinCashew](https://www.coincashew.com/coins/overview-ada/guide-how-to-build-a-haskell-stakepool-node)** | Best practices for BP/relay topology, KES rotation, security hardening | Industry-standard SPO guide |
| **[Cardano Developers](https://developers.cardano.org/docs/get-started/networks/overview/)** | Official network configs (mainnet, preview, preprod) | Canonical source for genesis files |

## Features

- 🏗️ **Multi-stage build** — Blink Labs source-compiled `cardano-node` + `cardano-cli`
- 🛠️ **Guild Operators tooling** — CNTools, gLiveView, topology updater, mithril scripts
- 📊 **Monitoring tools** — nview, txtop, EKG, Prometheus metrics
- 🔐 **Mithril ready** — Both mithril-client (fast sync) and mithril-signer (signing) with auto-restart keeper
- 🌐 **Multi-network** — Mainnet, Preview, Preprod, Guild configs included
- ☸️ **K3s native** — Designed for Kubernetes with proper SIGINT handling, preStop hooks, graceful 280s shutdown
- 🏷️ **Multi-arch** — AMD64 and ARM64 support
- 🎯 **Two profiles** — `bp` (block producer) and `relay` modes
- 📦 **Version-pinned** — Every component version is explicit and reproducible
- 🔒 **NetworkPolicy support** — Helm & K3s manifests include BP ingress whitelisting
- �� **CNCLI integration** — Slot leader logs, block validation, PoolTool.io reporting
- 💾 **DB backup/restore** — Automatic db backup before start and restore on crash
- 🏊 **Multi-pool support** — `POOL_DIR` / `POOL_NAME`-based private key directory layout
- 🔍 **Network mismatch detection** — Auto-detects wrong network config (e.g., mainnet config on preprod) and re-downloads
- 📈 **Legacy tracing** — Full 37-flag legacy trace config for gLiveView pool size, delegMapSize, utxoSize metrics
- 🛡️ **Port collision guard** — Prevents EKG/Prometheus port conflicts with automatic adjustment
- ✅ **Genesis hash verification** — Validates and auto-repairs genesis hashes on startup
- ⚡ **Smart config preservation** — Preserves local config modifications across restarts while detecting network mismatches

## Quick Start

### Pull the image

```bash
# Latest stable
docker pull ghcr.io/gvolcy/hybrid-node:latest

# Specific version
docker pull ghcr.io/gvolcy/hybrid-node:10.6.2
```

### Run as relay

```bash
docker run -d \
  --name cardano-relay \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v cardano-db:/opt/cardano/cnode/db \
  -v cardano-sockets:/opt/cardano/cnode/sockets \
  -p 3001:3001 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### Run as block producer

```bash
docker run -d \
  --name cardano-bp \
  -e NETWORK=mainnet \
  -e NODE_MODE=bp \
  -e NODE_PORT=6000 \
  -e POOL_NAME=MYPOOL \
  -e POOL_ID=abc123... \
  -e POOL_TICKER=MYTK \
  -e PT_API_KEY=my-pooltool-key \
  -e CNCLI_ENABLED=Y \
  -e CPU_CORES=4 \
  -e MITHRIL_SIGNER=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  -v cardano-keys:/opt/cardano/cnode/priv \
  -v cardano-sockets:/opt/cardano/cnode/sockets \
  -v cardano-guild-db:/opt/cardano/cnode/guild-db \
  -v cardano-mithril:/opt/cardano/cnode/mithril \
  -p 6000:6000 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### K3s / Kubernetes Deployment

```bash
# Using the included Helm chart
helm install cardano-relay ./helm/hybrid-node \
  --set mode=relay \
  --set network=mainnet

# Block producer with pool config
helm install cardano-bp ./helm/hybrid-node \
  --set mode=bp \
  --set network=mainnet \
  --set pool.name=MYPOOL \
  --set pool.id=abc123... \
  --set pool.ticker=MYTK \
  --set pool.ptApiKey=my-pooltool-key \
  --set cardano.cncliEnabled=true \
  --set cardano.cpuCores=4 \
  --set networkPolicy.enabled=true \
  --set networkPolicy.allowedRelayCIDRs[0]="1.2.3.4/32" \
  --set mithrilKeeper.enabled=true

# Or using the K3s manifests directly
kubectl apply -f k3s/relay.yaml
kubectl apply -f k3s/bp.yaml  # edit env vars first!
```

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | Network: `mainnet`, `preview`, `preprod`, `guild` |
| `NODE_MODE` | `relay` | Node mode: `relay` or `bp` |
| `NODE_PORT` | `6000` | cardano-node port |
| `CNODE_PORT` | `6000` | Same as NODE_PORT (for Guild script compatibility) |
| `TOPOLOGY` | (auto) | Path to custom topology.json |
| `CONFIG` | (auto) | Path to custom config.json |
| `CNODE_HOME` | `/opt/cardano/cnode` | Guild Operators home directory |
| `UPDATE_CHECK` | `N` | Disable guild-deploy update checks |
| `RTS_OPTS` | `-N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return` | GHC RTS options |
| `CPU_CORES` | (unset) | If set, overrides `-N` in RTS_OPTS (e.g. `4` → `-N4`) |
| `CUSTOM_PEERS` | (none) | Additional peers: `addr:port,addr:port,...` |

### Block Producer / Pool

| Variable | Default | Description |
|----------|---------|-------------|
| `POOL_NAME` | (unset) | Pool name (used for priv/pool/ subdirectory) |
| `POOL_ID` | (unset) | Pool ID hex (for CNCLI / PoolTool) |
| `POOL_TICKER` | (unset) | Pool ticker (for PoolTool) |
| `PT_API_KEY` | (unset) | PoolTool.io API key |
| `POOL_DIR` | (auto) | Explicit pool key directory; auto-detected from `POOL_NAME` if unset |
| `CNCLI_ENABLED` | `N` | Set to `Y` to enable CNCLI sync/leaderlog/validate/PoolTool |
| `CARDANO_BLOCK_PRODUCER` | (auto) | Set to `true` to force BP mode in Guild scripts |

### Mithril

| Variable | Default | Description |
|----------|---------|-------------|
| `MITHRIL_DOWNLOAD` | `N` | Set to `Y` to bootstrap DB via mithril-client on first start |
| `MITHRIL_SIGNER` | `N` | Set to `Y` to start mithril-signer alongside node (BP mode) |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `EKG_HOST` | `0.0.0.0` | EKG listen address |
| `PROMETHEUS_HOST` | `0.0.0.0` | Prometheus listen address |
| `PROMETHEUS_PORT` | `12798` | Prometheus metrics port |
| `EKG_PORT` | `12788` | EKG monitoring port (auto-adjusted if it collides with PROMETHEUS_PORT) |

### Backup / Restore

| Variable | Default | Description |
|----------|---------|-------------|
| `ENABLE_BACKUP` | `N` | Set to `Y` to back up db to db-backup/ before start |
| `ENABLE_RESTORE` | `N` | Set to `Y` to restore db from db-backup/ if db is missing or corrupt |

## Volume Mounts

| Mount Point | Purpose |
|-------------|---------|
| `/opt/cardano/cnode/db` | Blockchain database |
| `/opt/cardano/cnode/priv` | Pool keys (hot.skey, vrf.skey, op.cert) in `priv/pool/<POOL_NAME>/` |
| `/opt/cardano/cnode/sockets` | Node socket (`sockets/node.socket`) |
| `/opt/cardano/cnode/guild-db` | CNCLI & Guild databases |
| `/opt/cardano/cnode/mithril` | Mithril signer data |
| `/opt/cardano/cnode/logs` | Node logs |
| `/opt/cardano/cnode/scripts` | Custom scripts overlay |
| `/opt/cardano/cnode/files` | Config file overrides |

> **Note:** The node socket is at `sockets/node.socket` (not `db/node.socket`). Set `CARDANO_NODE_SOCKET_PATH` accordingly if accessing from outside the container.

## Helm Chart

The Helm chart is in `helm/hybrid-node/` and supports:

- **Pool configuration** — `pool.name`, `pool.id`, `pool.ticker`, `pool.ptApiKey`
- **NetworkPolicy** — `networkPolicy.enabled`, `networkPolicy.allowedRelayCIDRs` (restrict BP ingress to relay IPs only)
- **Mithril Keeper CronJob** — `mithrilKeeper.enabled` (auto-restarts crashed mithril-signer every 5 min)
- **All volume types** — PVC or hostPath per volume
- **Disk-pressure toleration** — Enabled by default
- **Recreate strategy** — Ensures single writer to DB
- **Graceful shutdown** — 300s termination grace period, preStop sends SIGINT with 280s clean-marker wait
- **Socket-based probes** — liveness/readiness use TCP socket check, not cardano-cli

See `helm/hybrid-node/values.yaml` for the full list of configurable values.

## K3s Raw Manifests

For non-Helm K3s deployments, see:

- `k3s/bp.yaml` — Block producer with NetworkPolicy, mithril-keeper CronJob, full RBAC
- `k3s/relay.yaml` — Relay with proper shutdown, all volumes

Edit the `CHANGE_ME` placeholders before applying.

## Included Tools

| Tool | Source | Purpose |
|------|--------|---------|
| `cardano-node` | Blink Labs (source-built) | The node itself |
| `cardano-cli` | Blink Labs (source-built) | CLI for node interaction |
| `cntools.sh` | Guild Operators | Pool management Swiss Army knife |
| `gLiveView.sh` | Guild Operators | Real-time node dashboard |
| `topologyUpdater.sh` | Guild Operators | P2P topology management |
| `cncli` | Guild Operators | Slot leader log, block validation |
| `mithril-client` | Blink Labs | Fast chain sync via Mithril snapshots |
| `mithril-signer` | Blink Labs | Mithril signing for SPOs |
| `nview` | Blink Labs | TUI node monitor |
| `txtop` | Blink Labs | Mempool display |

## Subcommands

The entrypoint supports subcommands for operational access:

```bash
# Enter gLiveView
docker exec -it cardano-bp /bin/bash -c "cd /opt/cardano/cnode && ./scripts/gLiveView.sh"

# Run CNTools
docker exec -it cardano-bp /opt/cardano/cnode/scripts/cntools.sh

# CNCLI operations (if enabled)
docker exec -it cardano-bp /opt/cardano/cnode/scripts/cncli.sh sync-status

# Topology updater
docker exec -it cardano-bp /opt/cardano/cnode/scripts/topologyUpdater.sh
```

## Building Locally

```bash
# Default build (latest versions)
docker build -t hybrid-node:latest .

# Specific cardano-node version
docker build --build-arg NODE_VERSION=10.6.2 -t hybrid-node:10.6.2 .

# Multi-arch build and push
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gvolcy/hybrid-node:10.6.2 \
  --push .
```

## Version Matrix

| Component | Version | Source |
|-----------|---------|--------|
| cardano-node | 10.6.2 | Blink Labs (source-built) |
| cardano-cli | 10.15.0.0 | Blink Labs (source-built) |
| mithril-client | 0.12.38 | Blink Labs |
| mithril-signer | 0.3.7 | Blink Labs |
| nview | 0.13.0 | Blink Labs |
| txtop | 0.14.0 | Blink Labs |
| Guild Scripts | master | Guild Operators |
| Base OS | Debian Bookworm Slim | — |

## Architecture

```
┌─────────────────────────────────────────────────────┐
│  Hybrid-Node Container                              │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Blink Labs Layer (Stage 1 - Build)           │  │
│  │  • cardano-node 10.6.2 (source-compiled)      │  │
│  │  • cardano-cli 10.15.0.0 (source-compiled)    │  │
│  │  • mithril-client, mithril-signer             │  │
│  │  • nview, txtop                               │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Guild Operators Layer (Stage 2)              │  │
│  │  • CNTools, gLiveView                         │  │
│  │  • topologyUpdater                            │  │
│  │  • cncli                                      │  │
│  │  • mithril-signer.sh, mithril-relay.sh        │  │
│  │  • Network configs                            │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  Hybrid Entrypoint (950+ lines)               │  │
│  │  • Auto-detects mode (bp/relay)               │  │
│  │  • CNCLI sync/leaderlog/validate/PoolTool     │  │
│  │  • Mithril bootstrap + signer auto-start      │  │
│  │  • DB backup/restore                          │  │
│  │  • EKG/Prometheus 0.0.0.0 binding             │  │
│  │  • 280s graceful SIGINT shutdown              │  │
│  │  • Multi-pool key directory support           │  │
│  │  • Guild env.sh + cncli.sh patching           │  │
│  │  • Healthcheck via socket probe               │  │
│  └───────────────────────────────────────────────┘  │
│                                                     │
│  debian:bookworm-slim + e2fsprogs + sudo            │
└─────────────────────────────────────────────────────┘
```

## Graceful Shutdown

The container handles shutdown carefully to protect the blockchain database:

1. **K8s preStop hook** sends `SIGINT` to cardano-node (not SIGTERM)
2. **Entrypoint trap** catches signals and forwards `SIGINT`
3. Node writes `db/clean` marker when DB is safely flushed
4. **280-second wait loop** checks for the clean marker
5. `terminationGracePeriodSeconds: 300` gives K8s enough headroom

This prevents DB corruption that requires hours of replay.

## Credits & Sources

- **[Guild Operators](https://github.com/cardano-community/guild-operators)** — MIT License
- **[Blink Labs](https://github.com/blinklabs-io/docker-cardano-node)** — Apache 2.0
- **[CoinCashew](https://www.coincashew.com/coins/overview-ada/guide-how-to-build-a-haskell-stakepool-node)** — SPO guides
- **[Cardano Developer Portal](https://developers.cardano.org/)** — Official network configs
- **[Intersect MBO](https://github.com/intersectmbo/cardano-node)** — The cardano-node source

## License

MIT License — See [LICENSE](LICENSE) for details.

---

*Built with ❤️ by [VolcyAda](https://github.com/volcyada) — Operators of VOLCY and SILEM stake pools on Cardano mainnet.*
