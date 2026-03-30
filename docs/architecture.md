# Architecture

## Overview

Hybrid-Node is a multi-chain node deployment framework. It provides shared infrastructure while keeping each blockchain stack isolated and modular.

```
┌──────────────────────────────────────────────────────────────────────┐
│                       Hybrid-Node Platform                           │
│                                                                      │
│  ┌──────────────────┐  ┌──────────────────┐  ┌────────────────────┐  │
│  │  Cardano Engine  │  │ ApexFusion Engine │  │  Midnight Engine   │  │
│  │                  │  │                   │  │                    │  │
│  │  • mainnet       │  │  • mainnet (afpm) │  │  • preview         │  │
│  │  • preprod       │  │  • testnet (afpt) │  │                    │  │
│  │  • preview       │  │                   │  │  Substrate-based   │  │
│  │  • guild         │  │                   │  │  (own image)       │  │
│  └────────┬─────────┘  └────────┬──────────┘  └────────┬───────────┘ │
│           │                     │                      │             │
│  ┌────────┴─────────────────────┴──────────┐  ┌────────┴───────────┐ │
│  │     Shared Platform Layer               │  │  Midnight Stack    │ │
│  │                                         │  │                    │ │
│  │  • cardano-node binary (IntersectMBO)   │  │  • midnight-node   │ │
│  │  • Entrypoint logic (1000+ lines)       │  │  • cardano-node    │ │
│  │  • Guild Operators tooling              │  │  • db-sync         │ │
│  │  • Monitoring (Prometheus, EKG, ...)    │  │  • ogmios          │ │
│  │  • Mithril (client + signer)            │  │  • postgres        │ │
│  │  • CNCLI (leader logs, PoolTool)        │  │  • key-inserter    │ │
│  │  • Graceful shutdown (SIGINT, 280s)     │  │                    │ │
│  │  • DB backup/restore                    │  │  K3s manifests     │ │
│  │  • Multi-pool key management            │  │  (no shared image) │ │
│  │                                         │  │                    │ │
│  │  Docker · Helm · debian:bookworm-slim   │  │  midnightntwrk/    │ │
│  └─────────────────────────────────────────┘  │  midnight-node     │ │
│                                               └────────────────────┘ │
└──────────────────────────────────────────────────────────────────────┘
```

## Design Principles

1. **Chain Separation** — Each blockchain has its own configs, k3s manifests, and documentation under `chains/<chain>/` (Cardano, ApexFusion, Midnight)
2. **Shared Platform** — The Docker image, entrypoint, and tooling are shared across all chains
3. **Network Selection at Runtime** — The `NETWORK` environment variable selects which chain and network to run
4. **Operator-Focused** — Designed for stake pool operators running production infrastructure
5. **Kubernetes-Native** — First-class K3s/K8s support with Helm charts and raw manifests

## Image Build

The Docker image is a multi-stage build:

| Stage | Purpose |
|-------|---------|
| **build** | Compile `cardano-node` from source (Haskell/GHC) |
| **tools** | Download pre-built companion binaries (mithril, nview, txtop, cncli) |
| **final** | Debian slim + Guild Operators scripts + all binaries + network configs |

## Runtime Flow

1. Entrypoint detects `NETWORK` and `NODE_MODE` (relay/bp)
2. Copies appropriate network configs from `hybrid-configs/<network>/`
3. Downloads missing configs from Guild Operators if needed
4. Validates genesis hashes
5. Configures ports, RTS options, monitoring
6. Starts `cardano-node` with proper signal handling
7. Optionally starts CNCLI, Mithril signer as background processes

## Midnight Stack

Midnight is a Substrate-based blockchain (not Ouroboros). It does **not** use the shared `cardano-node` Docker image or entrypoint. Instead, it runs `midnightntwrk/midnight-node` with a companion Cardano stack.

### Components

| Component | Image | Purpose |
|-----------|-------|---------|
| `midnight-node` | `midnightntwrk/midnight-node` | Substrate consensus node (libp2p P2P) |
| `cardano-node` | `ghcr.io/intersectmbo/cardano-node` | Partner chain (Cardano Preview) |
| `db-sync` | `ghcr.io/intersectmbo/cardano-db-sync` | Cardano chain indexer |
| `ogmios` | `cardanosolutions/ogmios` | Cardano WebSocket bridge |
| `postgres` | `postgres:15.3` | Database for db-sync |
| `key-inserter` | `curlimages/curl` | Sidecar: inserts validator keys via Substrate RPC |

### Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 9944 | WebSocket/HTTP | Substrate JSON-RPC |
| 30333 | TCP | libp2p P2P |
| 9615 | HTTP | Prometheus metrics |

### Validator Keys

Midnight validator keys are inserted at runtime via Substrate RPC (`author_insertKey`), not mounted as files:

- **AURA** (`aura`) — block production
- **GRANDPA** (`gran`) — finality
- **Sidechain** (`crch`) — cross-chain communication
