# 🔀 Hybrid-Node

**Multi-chain node deployment framework for Cardano, ApexFusion, and Midnight using Docker,
Helm, and K3s.**

[![Lint](https://github.com/gvolcy/Hybrid-Node/actions/workflows/lint.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/lint.yml)
[![Build](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/build.yml)
[![Test](https://github.com/gvolcy/Hybrid-Node/actions/workflows/test.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/test.yml)
[![Security](https://github.com/gvolcy/Hybrid-Node/actions/workflows/security.yml/badge.svg)](https://github.com/gvolcy/Hybrid-Node/actions/workflows/security.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Hybrid-Node is an operator-focused deployment framework for running Cardano, ApexFusion, and
Midnight blockchain nodes in production. Built with Docker, Helm, and K3s, it provides modular,
production-friendly deployment workflows for relay and block producer environments.

## Why This Exists

Running a stake pool shouldn't require stitching together five different repos, hand-editing
config files, and hoping your topology doesn't leak your BP to the public internet. Hybrid-Node
consolidates the entire SPO toolchain — source-built `cardano-node`, Guild Operators scripts,
Mithril, CNCLI, monitoring — into a single, version-pinned Docker image with a battle-tested
entrypoint that handles config precedence, genesis hash verification, P2P peer hardening,
graceful shutdown, and multi-pool key management out of the box. One image per chain. Any network.
Deploy in seconds.

> 🟢 **Production-validated** — Running across 17 nodes: Cardano mainnet (VOLCY & SILEM stake
> pools), ApexFusion Vector (AFPM/AFPT), and Midnight Preview networks.

---

## Chain Separation

Hybrid-Node builds **separate Docker images** for each chain. Each chain has its own Dockerfile,
version pins, and image tags — there is no ambiguous `latest` tag.

| Chain | Dockerfile | Node Version | Image Tag |
|-------|-----------|--------------|-----------|
| **Cardano** | `platform/docker/Dockerfile.cardano` | 10.6.3 | `ghcr.io/gvolcy/hybrid-node:cardano-10.6.3` |
| **ApexFusion** | `platform/docker/Dockerfile.apexfusion` | 10.1.4 | `ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4` |
| **Midnight** | Pre-built upstream image | 0.22.3 | `midnightntwrk/midnight-node:0.22.3` |

Version pins for each chain live in `chains/<chain>/versions.env`:

```bash
# chains/cardano/versions.env
NODE_VERSION=10.6.3
CLI_VERSION=10.15.1.0
G_ACCOUNT=cardano-community
GUILD_REPO=guild-operators
GUILD_DEPLOY_BRANCH=master

# chains/apexfusion/versions.env
NODE_VERSION=10.1.4
CLI_VERSION=9.4.1.0
G_ACCOUNT=Scitz0
GUILD_REPO=guild-operators-apex
GUILD_DEPLOY_BRANCH=main
```

> ⚠️ **ApexFusion uses an older cardano-node version** — do NOT bump it to match Cardano without
> confirming compatibility with the [ApexFusion prime-docker repo](https://github.com/APN-Fusion/prime-docker).

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

> 📖 Chain-specific docs: [Cardano](chains/cardano/README.md) · [ApexFusion](chains/apexfusion/README.md) · [Midnight](chains/midnight/README.md)

---

## Shared vs Isolated

Hybrid-Node uses a **shared platform** with **isolated chain configs**. Everything that is common
across chains lives in one place; everything chain-specific lives under its own directory.

| Layer | What | Where |
|-------|------|-------|
| **Shared** | Entrypoint, healthcheck, Helm chart, monitoring, shutdown logic | `platform/bin/`, `charts/hybrid-node/` |
| **Per-Chain** | Dockerfile, version pins, genesis files, topology, network configs, K3s manifests | `platform/docker/Dockerfile.<chain>`, `chains/<chain>/` |

Each chain has its own Dockerfile that sources the appropriate Guild Operators fork and
network configurations at build time.

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
├── Makefile                        # Chain-aware build targets
│
├── docs/                           # Documentation
│   ├── architecture.md             #   System design & runtime flow
│   └── deployment.md               #   Full deployment guide
│
├── platform/                       # Shared infrastructure
│   ├── docker/
│   │   ├── Dockerfile.cardano      #   Cardano multi-stage build
│   │   └── Dockerfile.apexfusion   #   ApexFusion multi-stage build
│   └── bin/
│       ├── entrypoint.sh           #   Unified entrypoint (1000+ lines)
│       └── healthcheck.sh          #   Container health check
│
├── chains/                         # Chain-specific modules
│   ├── cardano/                    #   ← Cardano chain
│   │   ├── README.md
│   │   ├── versions.env            #     Pinned versions (node, cli, guild)
│   │   ├── configs/                #     mainnet, preprod, preview, guild
│   │   └── k3s/                    #     bp.yaml, relay.yaml
│   │
│   ├── apexfusion/                 #   ← ApexFusion chain
│   │   ├── README.md
│   │   ├── versions.env            #     Pinned versions (node, cli, guild)
│   │   ├── configs/                #     afpm (mainnet), afpt (testnet)
│   │   └── k3s/                    #     bp.yaml, relay.yaml, testnet-relay.yaml
│   │
│   └── midnight/                   #   ← Midnight chain (Substrate-based)
│       ├── README.md
│       ├── versions.env            #     Pre-built image version
│       ├── configs/                #     preview
│       └── k3s/                    #     namespace.yaml, midnight-node.yaml,
│                                   #     cardano-stack.yaml
│
├── charts/                         # Helm charts
│   ├── hybrid-node/                #   Shared chart (Cardano/ApexFusion)
│   │   ├── values-relay-example.yaml
│   │   ├── values-bp-example.yaml
│   │   ├── values-apexfusion-relay.yaml
│   │   └── values-apexfusion-bp.yaml
│   └── midnight/                   #   Midnight chart (placeholder)
│
├── examples/                       # Example deployments
│   ├── single-node/
│   └── production/
│
└── .github/workflows/              # CI/CD (matrix: cardano × apexfusion)
    ├── build.yml
    ├── test.yml
    ├── release.yml
    ├── lint.yml
    └── security.yml
```

---

## Quick Start

### Build

```bash
# Build Cardano image (default)
make build

# Build ApexFusion image
make build-apexfusion

# Build both
make build-all

# See all available targets
make help
```

### Pull pre-built images

```bash
# Cardano
docker pull ghcr.io/gvolcy/hybrid-node:cardano-10.6.3

# ApexFusion
docker pull ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4
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
  ghcr.io/gvolcy/hybrid-node:cardano-10.6.3
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
  ghcr.io/gvolcy/hybrid-node:cardano-10.6.3
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
  ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4
```

### Midnight (K3s)

```bash
# Deploy the full Midnight stack (namespace + postgres + cardano companion + midnight node)
kubectl apply -f chains/midnight/k3s/namespace.yaml
kubectl apply -f chains/midnight/k3s/cardano-stack.yaml
kubectl apply -f chains/midnight/k3s/midnight-node.yaml
```

> ⚠️ Midnight uses its own Substrate-based image (`midnightntwrk/midnight-node`) — it does **not**
> use the shared Hybrid-Node Docker image. See [chains/midnight/README.md](chains/midnight/README.md)
> for full setup including secrets and validator key configuration.

### Kubernetes (K3s) — Cardano / ApexFusion

```bash
# Cardano
kubectl apply -f chains/cardano/k3s/relay.yaml

# ApexFusion
kubectl apply -f chains/apexfusion/k3s/relay.yaml

# Helm — Cardano relay
helm install cardano-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-relay-example.yaml

# Helm — ApexFusion relay
helm install apex-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-apexfusion-relay.yaml
```

> 📖 See [docs/deployment.md](docs/deployment.md) for full deployment guide including BP setup,
> volume mounts, and monitoring.

---

## Makefile Targets

```
make build              Build Docker image (CHAIN=cardano by default)
make build-cardano      Build Cardano image
make build-apexfusion   Build ApexFusion image
make build-all          Build all chain images
make push               Push image to registry
make push-all           Push all chain images
make run-relay          Run relay container
make run-bp             Run block producer container
make shell              Open shell in container
make version            Show current chain version
make versions           Show all chain versions
make clean              Remove images for current chain
make clean-all          Remove all chain images
make helm-relay         Deploy relay via Helm
make helm-bp            Deploy BP via Helm
make lint               Run all linters
make lint-yaml          Lint YAML files
make lint-docker        Lint Dockerfiles
make lint-all           Full lint suite
make logs               Tail relay logs
make logs-bp            Tail BP logs
make status             Show running containers
make help               Show this help
```

Override the chain with `CHAIN=`:

```bash
make build CHAIN=apexfusion
make run-relay CHAIN=apexfusion
make push CHAIN=apexfusion
```

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

> 📦 See the upstream [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases)
> for the latest version information, system requirements, and compatibility matrix.

---

## Design Goals

- 🧩 **Modular chain separation** — each chain has its own Dockerfile, version pins, and configs
- ☸️ **Kubernetes-native** — Helm charts and K3s manifests for production deployments
- 🛠️ **Operator-focused tooling** — CNTools, gLiveView, CNCLI, Mithril, nview, txtop
- 💾 **Persistent storage & recovery** — DB backup/restore, graceful 280s shutdown
- 🔒 **Relay / BP separation** — locked-down BP topology, NetworkPolicy support
- 📦 **Reproducible builds** — every component version is explicit and pinned per chain
- 🏗️ **Multi-arch** — AMD64 and ARM64 support

---

## Building

```bash
# Cardano (default)
make build

# ApexFusion
make build-apexfusion

# Both chains
make build-all

# Manual Docker build with version override
docker build -f platform/docker/Dockerfile.cardano \
  --build-arg NODE_VERSION=10.6.3 \
  -t hybrid-node:cardano-10.6.3 .

# Multi-arch Cardano
docker buildx build -f platform/docker/Dockerfile.cardano \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gvolcy/hybrid-node:cardano-10.6.3 --push .

# Multi-arch ApexFusion
docker buildx build -f platform/docker/Dockerfile.apexfusion \
  --platform linux/amd64,linux/arm64 \
  -t ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4 --push .
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
