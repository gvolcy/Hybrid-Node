# 🔀 Hybrid-Node

**A multi-chain node deployment framework for operators running Cardano and ApexFusion infrastructure using Docker, Helm, and K3s.**

[![Build and Push](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> 🟢 **Production-validated** — Running across 15 nodes: Cardano mainnet (VOLCY & SILEM stake pools) and ApexFusion Vector (AFPM/AFPT) networks.

---

## What is Hybrid-Node?

Hybrid-Node is **not** one node that does everything.

Hybrid-Node **is** one framework that can deploy multiple blockchain node stacks cleanly.

It provides a shared infrastructure platform while keeping each blockchain implementation isolated, modular, and production-friendly.

## Supported Chains

| Chain | Networks | Status |
|-------|----------|--------|
| **Cardano** | mainnet, preprod, preview, guild | ✅ Production |
| **ApexFusion** | afpm (mainnet), afpt (testnet) | ✅ Production |

## Design Goals

- 🧩 **Modular chain separation** — each chain has its own configs, manifests, and docs
- ☸️ **Kubernetes-native** — Helm charts and K3s manifests for production deployments
- 🛠️ **Operator-focused tooling** — CNTools, gLiveView, CNCLI, Mithril, nview, txtop
- 💾 **Persistent storage & recovery** — DB backup/restore, graceful 280s shutdown
- 🔒 **Clean relay / block producer separation** — locked-down BP topology, NetworkPolicy support
- 📦 **Reproducible builds** — every component version is explicit and pinned

## Repository Structure

```
Hybrid-Node/
├── README.md
├── LICENSE
│
├── docs/                          # Documentation
│   ├── architecture.md
│   └── deployment.md
│
├── platform/                      # Shared infrastructure
│   ├── docker/
│   │   └── Dockerfile             # Multi-stage build (all chains)
│   └── bin/
│       └── entrypoint.sh          # Unified entrypoint (1000+ lines)
│
├── chains/                        # Chain-specific modules
│   ├── cardano/
│   │   ├── README.md
│   │   ├── configs/               # mainnet, preprod, preview, guild
│   │   └── k3s/                   # bp.yaml, relay.yaml
│   │
│   └── apexfusion/
│       ├── README.md
│       ├── configs/               # afpm, afpt
│       └── k3s/                   # bp.yaml, relay.yaml, testnet-relay.yaml
│
├── charts/                        # Helm charts
│   └── hybrid-node/               # Shared Helm chart (network-selectable)
│
└── examples/                      # Example deployments
    ├── single-node/
    └── production/
```

## Quick Start

### Pull the image

```bash
docker pull ghcr.io/gvolcy/hybrid-node:latest
```

### Run a Cardano relay

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

### Run an ApexFusion relay

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

### Kubernetes (K3s)

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

> See [docs/deployment.md](docs/deployment.md) for full deployment guide including block producer setup.

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | `mainnet`, `preview`, `preprod`, `guild`, `afpm`, `afpt` |
| `NODE_MODE` | `relay` | `relay` or `bp` |
| `NODE_PORT` | `6000` | Node listening port |
| `CUSTOM_PEERS` | (none) | Additional peers: `addr:port,addr:port,...` |
| `CPU_CORES` | (unset) | Override RTS `-N` flag |

### Block Producer

| Variable | Default | Description |
|----------|---------|-------------|
| `POOL_NAME` | (unset) | Pool name (key directory: `priv/pool/<name>/`) |
| `POOL_ID` | (unset) | Pool ID hex (for CNCLI/PoolTool) |
| `POOL_TICKER` | (unset) | Pool ticker |
| `CNCLI_ENABLED` | `N` | Enable CNCLI sync/leaderlog/validate |
| `MITHRIL_SIGNER` | `N` | Enable Mithril signer (Cardano only) |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `PROMETHEUS_HOST` | `0.0.0.0` | Prometheus listen address |
| `PROMETHEUS_PORT` | `12798` | Prometheus metrics port |
| `EKG_HOST` | `0.0.0.0` | EKG listen address |

> See [docs/deployment.md](docs/deployment.md) for the complete environment variable reference.

## Included Tools

| Tool | Source | Purpose |
|------|--------|---------|
| `cardano-node` | [IntersectMBO](https://github.com/IntersectMBO/cardano-node) (source-built) | The node |
| `cardano-cli` | [IntersectMBO](https://github.com/IntersectMBO/cardano-cli) | CLI |
| `cntools.sh` | [Guild Operators](https://github.com/cardano-community/guild-operators) | Pool management |
| `gLiveView.sh` | Guild Operators | Real-time dashboard |
| `cncli` | [cardano-community](https://github.com/cardano-community/cncli) | Leader logs, validation |
| `mithril-client` | [IOG](https://github.com/input-output-hk/mithril) | Fast chain sync |
| `mithril-signer` | IOG | Mithril signing for SPOs |
| `nview` | [Blink Labs](https://github.com/blinklabs-io/nview) | TUI monitor |
| `txtop` | [Blink Labs](https://github.com/blinklabs-io/txtop) | Mempool display |

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   Hybrid-Node Platform                   │
│                                                          │
│  ┌────────────────────┐    ┌─────────────────────┐       │
│  │  Cardano Engine    │    │  ApexFusion Engine   │      │
│  │  mainnet/preprod/  │    │  afpm / afpt         │      │
│  │  preview/guild     │    │                      │      │
│  └────────┬───────────┘    └──────────┬───────────┘      │
│           │                           │                  │
│  ┌────────┴───────────────────────────┴───────────┐      │
│  │            Shared Platform Layer                │      │
│  │  • cardano-node (source-compiled)               │      │
│  │  • Guild Operators tooling                      │      │
│  │  • Monitoring (Prometheus, EKG, nview, txtop)   │      │
│  │  • Mithril (client + signer)                    │      │
│  │  • CNCLI (leader logs, validation, PoolTool)    │      │
│  │  • Entrypoint (1000+ lines, signal handling)    │      │
│  │  • Graceful shutdown (280s SIGINT drain)         │      │
│  └─────────────────────────────────────────────────┘      │
│  debian:bookworm-slim                                    │
└──────────────────────────────────────────────────────────┘
```

## Building

```bash
# Default build
docker build -f platform/docker/Dockerfile -t hybrid-node:latest .

# Specific node version
docker build -f platform/docker/Dockerfile \
  --build-arg NODE_VERSION=10.6.2 \
  -t hybrid-node:10.6.2 .

# Multi-arch
docker buildx build -f platform/docker/Dockerfile \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gvolcy/hybrid-node:latest --push .
```

## Credits

- [Guild Operators](https://github.com/cardano-community/guild-operators) — MIT License
- [Blink Labs](https://github.com/blinklabs-io/docker-cardano-node) — Apache 2.0
- [IntersectMBO](https://github.com/IntersectMBO/cardano-node) — cardano-node source
- [ApexFusion / Scitz0](https://github.com/Scitz0/guild-operators-apex) — APEX Guild fork
- [CoinCashew](https://www.coincashew.com/) — SPO best practices

## License

MIT License — See [LICENSE](LICENSE) for details.

---

*Built with ❤️ by [VolcyAda](https://github.com/gvolcy) — Operators of VOLCY and SILEM stake pools on Cardano mainnet.*
