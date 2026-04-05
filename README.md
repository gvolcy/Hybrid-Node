# 🔀 Hybrid-Node

**Multi-chain node deployment framework for Cardano, ApexFusion, and Midnight using Docker, Helm, and K3s.**

[![Lint](https://github.com/gvolcy/Hybrid-Node/actions/workflows/lint.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/lint.yml)
[![Build](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml)
[![Test](https://github.com/gvolcy/Hybrid-Node/actions/workflows/test.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Hybrid-Node is an operator-focused deployment framework for running Cardano, ApexFusion, and Midnight blockchain nodes in production. Built with Docker, Helm, and K3s, it provides modular, production-friendly deployment workflows for relay and block producer environments.

## Why This Exists

Running a stake pool shouldn't require stitching together five different repos, hand-editing config files, and hoping your topology doesn't leak your BP to the public internet. Hybrid-Node consolidates the entire SPO toolchain — source-built `cardano-node`, Guild Operators scripts, Mithril, CNCLI, monitoring — into a single, version-pinned Docker image with a battle-tested entrypoint that handles config precedence, genesis hash verification, P2P peer hardening, graceful shutdown, and multi-pool key management out of the box. One image. Any chain. Any network. Deploy in seconds.

> 🟢 **Production-validated** — Running across 17 nodes: Cardano mainnet (VOLCY & SILEM stake pools), ApexFusion Vector (AFPM/AFPT), and Midnight Preview networks.

---

## Supported Networks

### Cardano

| Network | `NETWORK=` | Status |
|---------|------------|--------|
| Mainnet | `mainnet` | ✅ Production |
| Preprod | `preprod` | ✅ Supported |
| Preview | `preview` | ✅ Supported |
| Guild (SanchoNet) | `guild` | ✅ Supported |

### ApexFusion

| Network | `NETWORK=` | Status |
|---------|------------|--------|
| Mainnet (Vector) | `afpm` | ✅ Production |
| Testnet (Vector) | `afpt` | ✅ Production |

### Midnight

| Network | Image | Status |
|---------|-------|--------|
| Preview | `midnightntwrk/midnight-node:0.22.3` | ✅ Production |

> ⚠️ Midnight uses its own Substrate-based node image — it does **not** use the shared Hybrid-Node Docker image.

> �� Chain-specific docs: [Cardano](chains/cardano/README.md) · [ApexFusion](chains/apexfusion/README.md) · [Midnight](chains/midnight/README.md)

---

## Shared vs Isolated

Hybrid-Node uses a **shared platform** with **isolated chain configs**. Everything that is common across chains lives in one place; everything chain-specific lives under its own directory.

| Layer | What | Where |
|-------|------|-------|
| **Shared** | Docker image, entrypoint, Helm chart, monitoring, shutdown logic | `platform/`, `charts/hybrid-node/` |
| **Isolated** | Genesis files, topology, network configs, K3s manifests | `chains/cardano/`, `chains/apexfusion/`, `chains/midnight/` |

The `NETWORK` environment variable selects which chain and network to run at container startup — the same image handles all of them.

---

## Architecture

```
                              Internet
                                 │
                      ┌──────────┴──────────┐
                      │    Relay Layer       │
                      └──────────┬──────────┘
                                 │
      ┌──────────────────────────┼──────────────────────────┐
      │                          │                          │
┌─────┴──────────┐    ┌─────────┴──────────┐    ┌──────────┴─────────┐
│ Cardano Stack  │    │ ApexFusion Stack    │    │  Midnight Stack    │
│                │    │                     │    │                    │
│  mainnet       │    │  mainnet (afpm)     │    │  preview           │
│  preprod       │    │  testnet (afpt)     │    │                    │
│  preview       │    │                     │    │  midnight-node     │
│  guild         │    │                     │    │  cardano companion │
└───────┬────────┘    └─────────┬───────────┘    │  db-sync + ogmios │
        │                       │                └──────────┬────────┘
        │                       │                           │
┌───────┴───────────────────────┴───────────────────────────┘
│
│  ┌──────────────────────────────────────────────────────────┐
│  │      Shared Platform Layer (Cardano / ApexFusion)        │
│  │                                                          │
│  │  • cardano-node (source-compiled from IntersectMBO)      │
│  │  • Guild Operators tooling (CNTools, gLiveView)          │
│  │  • Monitoring (Prometheus, EKG, nview, txtop)            │
│  │  • Mithril (client + signer)                             │
│  │  • CNCLI (leader logs, validation, PoolTool)             │
│  │  • Graceful shutdown (280s SIGINT drain)                  │
│  │  • DB backup / restore                                   │
│  │  • Multi-pool key management                             │
│  │                                                          │
│  │  Docker · Helm · K3s · debian:bookworm-slim              │
│  └──────────────────────────────────────────────────────────┘
│
│  ┌──────────────────────────────────────────────────────────┐
│  │      Midnight Stack (Substrate-based, own image)         │
│  │                                                          │
│  │  • midnight-node (Substrate/libp2p)                      │
│  │  • Companion Cardano node + DB-Sync + Ogmios             │
│  │  • Validator key insertion via RPC                        │
│  │  • K3s manifests (no shared Docker image)                │
│  └──────────────────────────────────────────────────────────┘
└─────────────────────────────────────────────────────────────
```

---

## Project Structure

```
Hybrid-Node/
├── README.md
├── LICENSE
│
├── docs/                           # Documentation
│   ├── architecture.md             #   System design & runtime flow
│   └── deployment.md               #   Full deployment guide
│
├── platform/                       # Shared infrastructure (all chains)
│   ├── docker/
│   │   └── Dockerfile              #   Multi-stage build
│   └── bin/
│       └── entrypoint.sh           #   Unified entrypoint (1000+ lines)
│
├── chains/                         # Chain-specific modules
│   ├── cardano/                    #   ← Cardano chain
│   │   ├── README.md
│   │   ├── configs/                #     mainnet, preprod, preview, guild
│   │   └── k3s/                    #     bp.yaml, relay.yaml
│   │
│   ├── apexfusion/                 #   ← ApexFusion chain
│   │   ├── README.md
│   │   ├── configs/                #     afpm (mainnet), afpt (testnet)
│   │   └── k3s/                    #     bp.yaml, relay.yaml, testnet-relay.yaml
│   │
│   └── midnight/                   #   ← Midnight chain (Substrate-based)
│       ├── README.md
│       ├── configs/                #     preview
│       └── k3s/                    #     namespace.yaml, midnight-node.yaml,
│                                   #     cardano-stack.yaml
│
├── charts/                         # Helm charts
│   ├── hybrid-node/                #   Shared chart (Cardano/ApexFusion)
│   └── midnight/                   #   Midnight chart (placeholder)
│
├── examples/                       # Example deployments
│   ├── single-node/
│   └── production/
│
└── .github/workflows/              # CI/CD
    └── build.yml
```

---

## Quick Start

### Pull the image

```bash
docker pull ghcr.io/gvolcy/hybrid-node:latest
```

### Cardano Relay

```bash
docker run -d \
  --name cardano-relay \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v cardano-db:/opt/cardano/cnode/db \
  -p 3001:3001 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### Cardano Block Producer

```bash
docker run -d \
  --name cardano-bp \
  -e NETWORK=mainnet \
  -e NODE_MODE=bp \
  -e NODE_PORT=6000 \
  -e POOL_NAME=MYPOOL \
  -e CNCLI_ENABLED=Y \
  -e MITHRIL_SIGNER=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  -v cardano-keys:/opt/cardano/cnode/priv \
  -p 6000:6000 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### ApexFusion Relay

```bash
docker run -d \
  --name apex-relay \
  -e NETWORK=afpm \
  -e NODE_MODE=relay \
  -e NODE_PORT=4550 \
  -v apex-db:/opt/cardano/cnode/db \
  -p 4550:4550 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### Midnight (K3s)

```bash
# Deploy the full Midnight stack (namespace + postgres + cardano companion + midnight node)
kubectl apply -f chains/midnight/k3s/namespace.yaml
kubectl apply -f chains/midnight/k3s/cardano-stack.yaml
kubectl apply -f chains/midnight/k3s/midnight-node.yaml
```

> ⚠️ Midnight uses its own Substrate-based image (`midnightntwrk/midnight-node`) — it does **not** use the shared Hybrid-Node Docker image. See [chains/midnight/README.md](chains/midnight/README.md) for full setup including secrets and validator key configuration.

### Kubernetes (K3s) — Cardano / ApexFusion

```bash
# Cardano
kubectl apply -f chains/cardano/k3s/relay.yaml

# ApexFusion
kubectl apply -f chains/apexfusion/k3s/relay.yaml

# Helm
helm install cardano-relay ./charts/hybrid-node \
  --set cardano.network=mainnet \
  --set cardano.mode=relay
```

> 📖 See [docs/deployment.md](docs/deployment.md) for full deployment guide including BP setup, volume mounts, and monitoring.

---

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | `mainnet`, `preview`, `preprod`, `guild`, `afpm`, `afpt` |
| `NODE_MODE` | `relay` | `relay` or `bp` |
| `NODE_PORT` | `6000` | Node listening port |
| `CUSTOM_PEERS` | — | Additional peers: `addr:port,addr:port,...` |
| `CPU_CORES` | — | Override RTS `-N` flag |

### Block Producer

| Variable | Default | Description |
|----------|---------|-------------|
| `POOL_NAME` | — | Pool name (key directory: `priv/pool/<name>/`) |
| `POOL_ID` | — | Pool ID hex (for CNCLI / PoolTool) |
| `POOL_TICKER` | — | Pool ticker |
| `CNCLI_ENABLED` | `N` | Enable CNCLI sync / leaderlog / validate |
| `MITHRIL_SIGNER` | `N` | Enable Mithril signer (Cardano only) |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `PROMETHEUS_HOST` | `0.0.0.0` | Prometheus listen address |
| `PROMETHEUS_PORT` | `12798` | Prometheus metrics port |
| `EKG_HOST` | `0.0.0.0` | EKG listen address |

---

## Included Tools

| Tool | Source | Purpose |
|------|--------|----------|
| `cardano-node` | [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) (source-built) | Ouroboros consensus node |
| `cardano-cli` | [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) | Transaction and governance CLI |
| `cntools.sh` | [Guild Operators](https://github.com/cardano-community/guild-operators) | Pool registration & management |
| `gLiveView.sh` | Guild Operators | Real-time node dashboard |
| `cncli` | [cardano-community/cncli](https://github.com/cardano-community/cncli) | Slot leader logs, block validation, PoolTool |
| `mithril-client` | [input-output-hk/mithril](https://github.com/input-output-hk/mithril) | Fast chain sync via certified snapshots |
| `mithril-signer` | [input-output-hk/mithril](https://github.com/input-output-hk/mithril) | Mithril signing protocol for SPOs |
| `nview` | [blinklabs-io/nview](https://github.com/blinklabs-io/nview) | TUI node monitor |
| `txtop` | [blinklabs-io/txtop](https://github.com/blinklabs-io/txtop) | Mempool transaction display |

> 📦 See the upstream [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases) for the latest version information, system requirements, and compatibility matrix.

---

## Design Goals

- 🧩 **Modular chain separation** — each chain has its own configs, manifests, and docs
- ☸️ **Kubernetes-native** — Helm charts and K3s manifests for production deployments
- 🛠️ **Operator-focused tooling** — CNTools, gLiveView, CNCLI, Mithril, nview, txtop
- 💾 **Persistent storage & recovery** — DB backup/restore, graceful 280s shutdown
- 🔒 **Relay / BP separation** — locked-down BP topology, NetworkPolicy support
- 📦 **Reproducible builds** — every component version is explicit and pinned
- 🏗️ **Multi-arch** — AMD64 and ARM64 support

---

## Building

```bash
# Default build
docker build -f platform/docker/Dockerfile -t hybrid-node:latest .

# Specific node version
docker build -f platform/docker/Dockerfile \
  --build-arg NODE_VERSION=10.7.0 \
  -t hybrid-node:10.7.0 .

# Multi-arch
docker buildx build -f platform/docker/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gvolcy/hybrid-node:latest --push .
```

---

## Credits

- [Guild Operators](https://github.com/cardano-community/guild-operators) — MIT License
- [Blink Labs](https://github.com/blinklabs-io/docker-cardano-node) — Apache 2.0
- [IntersectMBO](https://github.com/IntersectMBO/cardano-node) — cardano-node source
- [ApexFusion / Scitz0](https://github.com/Scitz0/guild-operators-apex) — APEX Guild fork
- [CoinCashew](https://www.coincashew.com/) — SPO best practices
- [Midnight Network](https://midnight.network/) — Midnight node & documentation

## License

MIT — See [LICENSE](LICENSE) for details.

---

*Built with ❤️ by [VolcyAda](https://github.com/gvolcy) — Operators of VOLCY and SILEM stake pools on Cardano mainnet.*
