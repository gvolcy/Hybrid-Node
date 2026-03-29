# Architecture

## Overview

Hybrid-Node is a multi-chain node deployment framework. It provides shared infrastructure while keeping each blockchain stack isolated and modular.

```
┌─────────────────────────────────────────────────────────┐
│                    Hybrid-Node Platform                  │
│                                                         │
│  ┌────────────────────┐    ┌────────────────────┐       │
│  │   Cardano Engine   │    │ ApexFusion Engine   │      │
│  │                    │    │                     │      │
│  │  • mainnet         │    │  • afpm (mainnet)   │      │
│  │  • preprod         │    │  • afpt (testnet)   │      │
│  │  • preview         │    │                     │      │
│  │  • guild           │    │                     │      │
│  └────────┬───────────┘    └────────┬────────────┘      │
│           │                         │                   │
│  ┌────────┴─────────────────────────┴────────────┐      │
│  │           Shared Platform Layer                │      │
│  │                                                │      │
│  │  • cardano-node binary (IntersectMBO)          │      │
│  │  • Entrypoint logic (1000+ lines)              │      │
│  │  • Guild Operators tooling                     │      │
│  │  • Monitoring (Prometheus, EKG, nview, txtop)  │      │
│  │  • Mithril (client + signer)                   │      │
│  │  • CNCLI (leader logs, validation, PoolTool)   │      │
│  │  • Graceful shutdown (SIGINT, 280s drain)       │      │
│  │  • DB backup/restore                           │      │
│  │  • Multi-pool key management                   │      │
│  └────────────────────────────────────────────────┘      │
│                                                         │
│  debian:bookworm-slim                                   │
└─────────────────────────────────────────────────────────┘
```

## Design Principles

1. **Chain Separation** — Each blockchain has its own configs, k3s manifests, and documentation under `chains/<chain>/`
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
