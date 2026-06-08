# Architecture

## Infrastructure Topology

Hybrid-Node runs across a distributed fleet of dedicated hosts, each with a specific role:

```
┌─────────────────────────────────────────────────────────────────────────┐
│                      Hybrid-Node Infrastructure                        │
│                                                                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │   main1     │  │   main3     │  │   main4     │  │   main5     │  │
│  │  BP Host    │  │  Relay/K3s  │  │  Relay      │  │  Relay/AI   │  │
│  │             │  │             │  │             │  │             │  │
│  │ Cardano BP  │  │ Cardano     │  │ Cardano     │  │ Cardano     │  │
│  │ (mainnet)   │  │ Relay       │  │ Relay       │  │ Relay       │  │
│  │             │  │             │  │             │  │             │  │
│  │ ApexFusion  │  │ ApexFusion  │  │ ApexFusion  │  │ AI Sandbox  │  │
│  │ BP (afpm)   │  │ Relay       │  │ Relay       │  │ Ollama      │  │
│  │             │  │             │  │             │  │             │  │
│  │ VOLCY Pool  │  │ Discord     │  │             │  │             │  │
│  │ SILEM Pool  │  │ Bots (K3s)  │  │             │  │             │  │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  │
│         │                │                │                │          │
│         └────────────────┴────────────────┴────────────────┘          │
│                          │ Tailscale Mesh                             │
│                          │                                            │
│  ┌─────────────┐  ┌─────┴───────┐                                    │
│  │   main2     │  │   main6     │                                    │
│  │  Testnet    │  │  NAS/Backup │                                    │
│  │             │  │             │                                    │
│  │ Preview     │  │ DB Backups  │                                    │
│  │ Preprod     │  │ Snapshots   │                                    │
│  │ Midnight    │  │ AI Memory   │                                    │
│  │ Guild       │  │ Cold Keys   │                                    │
│  │ AFPT        │  │ (offline)   │                                    │
│  └─────────────┘  └─────────────┘                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Host Roles

| Host | Role | Networks | Notes |
|------|------|----------|-------|
| **main1** | Block Producers | Cardano mainnet, ApexFusion afpm | VOLCY + SILEM pools. Locked down — no public ports. |
| **main2** | Testnet / Dev | Preview, Preprod, Guild, AFPT, Midnight | All non-production workloads. |
| **main3** | Relays + K3s | Cardano mainnet, ApexFusion afpm | Primary relay. Runs K3s cluster (Discord bots). |
| **main4** | Relays | Cardano mainnet, ApexFusion afpm | Secondary relay for redundancy. |
| **main5** | Relays + AI | Cardano mainnet | Tertiary relay. AI sandbox (Ollama, local models). |
| **main6** | NAS / Storage | — | Backup target. DB snapshots, AI memory, cold key storage (offline). |

### Network Security

```
Internet ──→ main3/main4/main5 (relays, public ports)
                    │
                    ├── Tailscale mesh (private)
                    │
              main1 (BPs — NO public ports, relay-only peering)
              main2 (testnets — Tailscale only)
              main6 (NAS — Tailscale only, no inbound)
```

- **Block producers** are never directly reachable from the internet
- All BP traffic routes through relays only
- Tailscale mesh connects all hosts (100.x.x.x addresses)
- main6 (NAS) has no inbound connections — pull-only backups

---

## Logical Architecture

```
Hybrid-Node
├── Cardano
│   ├── mainnet        → BP (main1) + Relays (main3, main4, main5)
│   ├── preprod        → main2
│   ├── preview        → main2
│   └── guild          → main2
│
├── ApexFusion
│   ├── mainnet (afpm) → BP (main1) + Relays (main3, main4)
│   └── testnet (afpt) → main2
│
├── Midnight
│   └── preview        → main2 (K3s stack)
│
└── Shared Platform
    ├── Docker images   → Dockerfile.cardano, Dockerfile.apexfusion
    ├── Entrypoint      → platform/bin/entrypoint.sh (1100+ lines)
    ├── Health check    → platform/bin/healthcheck.sh
    ├── Helm chart      → charts/hybrid-node/
    ├── Monitoring      → monitoring/ (Prometheus, Grafana, alerts)
    ├── Scripts         → scripts/ (health checks, operator tools)
    └── CI/CD           → .github/workflows/ (build, test, lint, security, release)
```

---

## Software Architecture

### Image Build Pipeline

Each chain has its own Dockerfile and version pins:

| Chain | Dockerfile | Node | CLI | Guild Source |
|-------|-----------|------|-----|-------------|
| Cardano | `Dockerfile.cardano` | 11.0.1 | 11.0.0.0 | cardano-community/guild-operators (master) |
| ApexFusion | `Dockerfile.apexfusion` | 10.1.4 | 9.4.1.0 | Scitz0/guild-operators-apex (main) |
| Midnight | Pre-built upstream | — | — | midnightntwrk/midnight-node |

```
┌──────────────────────────────────────────────────────────────┐
│                    Multi-Stage Docker Build                    │
│                                                                │
│  Stage 1: build        Stage 2: tools        Stage 3: final   │
│  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐   │
│  │ GHC 9.6.6    │     │ Download:    │     │ debian:slim  │   │
│  │ Cabal 3.12   │     │  mithril     │     │ + node bin   │   │
│  │              │     │  cncli       │     │ + cli bin    │   │
│  │ Compile:     │     │  nview       │     │ + tools      │   │
│  │  cardano-    │     │  txtop       │     │ + guild ops  │   │
│  │  node        │     │  cardano-cli │     │ + configs    │   │
│  │              │     │              │     │ + entrypoint │   │
│  └──────────────┘     └──────────────┘     └──────────────┘   │
│                                                                │
│  Image: ghcr.io/gvolcy/hybrid-node:<chain>-<version>          │
└──────────────────────────────────────────────────────────────┘
```

### Runtime Flow

```
Container Start
      │
      ▼
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐
│ Detect       │────▶│ Download /    │────▶│ Validate genesis │
│ NETWORK +    │     │ copy configs │     │ hashes           │
│ NODE_MODE    │     │              │     │                  │
└─────────────┘     └──────────────┘     └────────┬─────────┘
                                                   │
      ┌────────────────────────────────────────────┘
      │
      ▼
┌─────────────┐     ┌──────────────┐     ┌──────────────────┐
│ Configure    │────▶│ Start        │────▶│ Background       │
│ topology,    │     │ cardano-node │     │ services:        │
│ ports, RTS   │     │ (SIGINT      │     │ • CNCLI          │
│              │     │  handling)   │     │ • Mithril signer │
└─────────────┘     └──────────────┘     │ • PoolTool       │
                                          │ • Monitoring     │
                                          └──────────────────┘
```

### Graceful Shutdown Sequence

```
SIGTERM received (K8s pod termination / docker stop)
      │
      ▼
┌──────────────────────────────────────────────────┐
│ 1. Entrypoint (PID 1) traps SIGTERM and sends     │
│    SIGINT straight to cardano-node                 │
│ 2. Node flushes its in-memory ledger DB to disk    │
│ 3. CNCLI + mithril-signer helpers stopped          │
│    concurrently (mithril-signer bounded to 15s)    │
│ 4. Entrypoint waits for the node to exit & reaps   │
│    it (up to 540s; watchdog SIGKILLs if exceeded)  │
│ 5. Container exits cleanly                          │
│                                                    │
│ terminationGracePeriodSeconds: 600                 │
│ (60s headroom beyond the 540s node-drain cap)      │
│                                                    │
│ No preStop hook — the entrypoint receives SIGTERM  │
│ directly, so the signal always reaches the node.   │
└──────────────────────────────────────────────────┘
```

---

## Midnight Stack

Midnight is a Substrate-based blockchain (not Ouroboros). It does **not** use the shared
`cardano-node` Docker image or entrypoint.

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

Midnight validator keys are inserted at runtime via Substrate RPC (`author_insertKey`),
not mounted as files:

- **AURA** (`aura`) — block production
- **GRANDPA** (`gran`) — finality
- **Sidechain** (`crch`) — cross-chain communication

---

## Port Map

### Cardano / ApexFusion

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| cardano-node (relay) | 3001 | TCP | Public — advertised in topology |
| cardano-node (BP) | 6000 | TCP | Private — relay-only access |
| ApexFusion (relay) | 4550 | TCP | Public — advertised in topology |
| ApexFusion (BP) | 4560 | TCP | Private — relay-only access |
| Prometheus metrics | 12798 | HTTP | Internal only |
| EKG | 12788 | HTTP | Internal only |
| Node socket | — | Unix | `/opt/cardano/cnode/sockets/node.socket` |

### Midnight

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| midnight-node P2P | 30333 | TCP | Public |
| midnight-node RPC | 9944 | WebSocket | Internal only |
| midnight-node metrics | 9615 | HTTP | Internal only |
| cardano-node (companion) | 3001 | TCP | Internal only |
| ogmios | 1337 | WebSocket | Internal only |
| postgres | 5432 | TCP | Internal only |

---

## Design Principles

1. **Chain Separation** — Each blockchain has its own Dockerfile, version pins, configs, and K3s manifests
2. **Shared Platform** — Entrypoint, healthcheck, and Helm chart logic are shared across Cardano/ApexFusion
3. **Network Selection at Runtime** — The `NETWORK` environment variable selects which chain and network to run
4. **Operator-Focused** — Designed for stake pool operators running production infrastructure
5. **Kubernetes-Native** — First-class K3s/K8s support with Helm charts and raw manifests
6. **No Ambiguous Tags** — Images are tagged `<chain>-<version>`, never just `latest`
7. **Version Isolation** — Cardano and ApexFusion can run different node versions without conflict
