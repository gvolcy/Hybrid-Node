# 🔀 Hybrid-Node

**A hybrid Cardano node Docker image combining the best of Guild Operators and Blink Labs for Kubernetes (K3s) deployments.**

[![Build and Push](https://github.com/volcyada/Hybrid-Node/actions/workflows/build.yml/badge.svg)](https://github.com/volcyada/Hybrid-Node/actions/workflows/build.yml)
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
- 📊 **Monitoring tools** — nview, txtop (from Blink Labs)
- 🔐 **Mithril ready** — Both mithril-client (fast sync) and mithril-signer (signing)
- 🌐 **Multi-network** — Mainnet, Preview, Preprod, Guild configs included
- ☸️ **K3s native** — Designed for Kubernetes with proper signal handling
- 🏷️ **Multi-arch** — AMD64 and ARM64 support
- 🎯 **Two profiles** — `bp` (block producer) and `relay` modes
- 📦 **Version-pinned** — Every component version is explicit and reproducible

## Quick Start

### Pull the image

```bash
# Latest stable
docker pull ghcr.io/volcyada/hybrid-node:latest

# Specific version
docker pull ghcr.io/volcyada/hybrid-node:10.6.2
```

### Run as relay

```bash
docker run -d \
  --name cardano-relay \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v cardano-db:/opt/cardano/cnode/db \
  -p 3001:3001 \
  ghcr.io/volcyada/hybrid-node:latest
```

### Run as block producer

```bash
docker run -d \
  --name cardano-bp \
  -e NETWORK=mainnet \
  -e NODE_MODE=bp \
  -e NODE_PORT=6000 \
  -v cardano-db:/opt/cardano/cnode/db \
  -v cardano-keys:/opt/cardano/cnode/priv \
  -p 6000:6000 \
  ghcr.io/volcyada/hybrid-node:latest
```

### K3s Deployment

```bash
# Using the included Helm chart
helm install cardano-relay ./helm/hybrid-node \
  --set mode=relay \
  --set network=mainnet

# Or using the K3s manifests directly
kubectl apply -f k3s/relay.yaml
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | Network: `mainnet`, `preview`, `preprod`, `guild` |
| `NODE_MODE` | `relay` | Node mode: `relay` or `bp` |
| `NODE_PORT` | `6000` | cardano-node port |
| `TOPOLOGY` | (auto) | Path to custom topology.json (overrides default) |
| `CONFIG` | (auto) | Path to custom config.json (overrides default) |
| `MITHRIL_DOWNLOAD` | `N` | Set to `Y` to bootstrap DB via mithril-client on first start |
| `MITHRIL_SIGNER` | `N` | Set to `Y` to start mithril-signer alongside node (BP mode) |
| `CNODE_HOME` | `/opt/cardano/cnode` | Guild Operators home directory |
| `UPDATE_CHECK` | `N` | Disable guild-deploy update checks |
| `RTS_OPTS` | `-N2 -I0 -A16m -qg -qb --disable-delayed-os-memory-return` | GHC RTS options |
| `CUSTOM_PEERS` | (none) | Additional peers: `addr:port,addr:port,...` |

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

## Building Locally

```bash
# Default build (latest versions)
docker build -t hybrid-node:latest .

# Specific cardano-node version
docker build --build-arg NODE_VERSION=10.6.2 -t hybrid-node:10.6.2 .

# Multi-arch build and push
docker buildx build --platform linux/amd64,linux/arm64 \
  -t ghcr.io/volcyada/hybrid-node:10.6.2 \
  --push .
```

## Version Matrix

| Component | Version | Source |
|-----------|---------|--------|
| cardano-node | 10.6.2 | Blink Labs (source-built) |
| cardano-cli | 10.14.0.0 | Blink Labs (source-built) |
| mithril-client | 0.12.38 | Blink Labs |
| mithril-signer | 0.3.7 | Blink Labs |
| nview | 0.13.0 | Blink Labs |
| txtop | 0.14.0 | Blink Labs |
| Guild Scripts | master | Guild Operators |
| Base OS | Debian Bookworm Slim | — |

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Hybrid-Node Container                          │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  Blink Labs Layer (Stage 1 - Build)     │    │
│  │  • cardano-node (source-compiled)       │    │
│  │  • cardano-cli (source-compiled)        │    │
│  │  • mithril-client, mithril-signer       │    │
│  │  • nview, txtop                         │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  Guild Operators Layer (Stage 2)        │    │
│  │  • CNTools, gLiveView                   │    │
│  │  • topologyUpdater                      │    │
│  │  • cncli                                │    │
│  │  • mithril-signer.sh, mithril-relay.sh  │    │
│  │  • Network configs                      │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  ┌─────────────────────────────────────────┐    │
│  │  Hybrid Entrypoint                      │    │
│  │  • Auto-detects mode (bp/relay)         │    │
│  │  • Mithril bootstrap support            │    │
│  │  • Signal handling (SIGTERM/SIGINT)      │    │
│  │  • Healthcheck integration              │    │
│  └─────────────────────────────────────────┘    │
│                                                 │
│  debian:bookworm-slim                           │
└─────────────────────────────────────────────────┘
```

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
