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
│  │ Leios       │  │             │                                    │
│  └─────────────┘  └─────────────┘                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Host Roles

| Host | Role | Networks | Notes |
|------|------|----------|-------|
| **main1** | Block Producers | Cardano mainnet, ApexFusion afpm | VOLCY + SILEM pools. Locked down — no public ports. |
| **main2** | Testnet / Dev | Preview, Preprod, Guild, AFPT, Midnight, Leios | All non-production workloads. |
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
├── Leios (Ouroboros Leios — prototype)
│   └── musashi (leios) → main2 (Musashi Dojo testnet, magic 164)
│
├── Midnight
│   └── preview        → main2 (K3s stack)
│
└── Shared Platform
    ├── Docker images   → Dockerfile.cardano, Dockerfile.apexfusion, Dockerfile.leios
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
| Leios | `Dockerfile.leios` | `leios-prototype` branch (reports 11.0.1-leios-prototype) | built from source (same branch) | cardano-community/guild-operators (master) |
| Midnight | Pre-built upstream | — | — | midnightntwrk/midnight-node |

> Leios builds **both** `cardano-node` and `cardano-cli` from the `leios-prototype`
> branch (the branch's `cabal.project` pins patched `ouroboros-consensus` /
> `ouroboros-network`), so it does not consume a tagged release or the prebuilt
> `cardano-cli` used by the other chains.

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

## Leios / Musashi Dojo Stack

Leios (Ouroboros Leios) is the [Musashi Dojo](https://www.musashi.network/) public
testnet for Cardano's next-generation high-throughput consensus (CIP-0164). It uses
the shared `cardano-node` lineage and the same Hybrid-Node entrypoint/Helm/K3s
platform as Cardano and ApexFusion, but on a **prototype** build with extra layers.

### How it differs from Cardano/ApexFusion

| Aspect | Cardano / ApexFusion | Leios (Musashi) |
|--------|----------------------|-----------------|
| Node binary | Tagged release | **Prototype** `leios-prototype` branch (reports `11.0.1-leios-prototype`) |
| Consensus | Ouroboros Praos | Ouroboros **Leios** over Praos (endorser blocks + committee validation) |
| Ledger eras | 4 (byron→conway) | **5** — adds **Dijkstra** (`dijkstra-genesis.json`) |
| Extra store | — | **Leios SQLite DB** (`leios.db`, `LeiosDbConfig`) for endorser-block txs |
| Network magic | per-network | **164** (`--testnet-magic 164`) |
| Bootstrap | topology localRoots | bootstrap peer `leios-node.play.dev.cardano.org:3001` + `peer-snapshot.json` |
| Mithril | available (Cardano) | **not available** — sync from bootstrap peer |
| Block producer | KES + VRF + op.cert | additionally needs **BLS keys** (`--shelley-bls-key`) — pending upstream |

### Consensus data flow (Leios layer)

```
                Praos chain (base security)
                        │
   ┌────────────────────┼────────────────────┐
   │   BP forges a ranking block (RB) as in Praos
   │                    │
   │   Leios layer adds endorser blocks (EB):
   │     • EBs reference extra txs Praos leaves out
   │     • diffused + stored in leios.db (SQLite)
   │     • committee validates EBs before ledger inclusion
   └────────────────────┼────────────────────┘
                        ▼
            Higher throughput, same Praos security
```

### Runtime specifics (entrypoint)

The shared [entrypoint](../platform/bin/entrypoint.sh) handles `NETWORK=leios`:

- Downloads configs from cardano-playground `next-2026-05-15` (incl. the 5th era
  `dijkstra-genesis.json` and `peer-snapshot.json` referenced by topology)
- Maps `--testnet-magic 164` for `cardano-cli` queries
- Skips Mithril (unavailable for Leios)
- Relay-first; BP forging deferred until BLS key support lands

### Image build

```bash
make build-leios                 # builds from the leios-prototype branch
# override if upstream moves the branch:
make build-leios NODE_BUILD_REF=leios-prototype \
                 NODE_REPO=https://github.com/IntersectMBO/cardano-node.git
```

---

## Port Map

### Leios / Musashi Dojo

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| cardano-node (relay) | 3001 | TCP | Public — peers with `leios-node.play.dev.cardano.org:3001` |
| cardano-node (BP) | 3001 | TCP | Private — relay-only (BP pending BLS support) |
| Prometheus metrics | 12798 | HTTP | Internal only |
| EKG | 12788 | HTTP | Internal only |
| Leios DB | — | SQLite | `leios.db` (endorser-block tx store) |
| Node socket | — | Unix | `/opt/cardano/cnode/sockets/node.socket` |

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
2. **Shared Platform** — Entrypoint, healthcheck, and Helm chart logic are shared across Cardano/ApexFusion/Leios
3. **Network Selection at Runtime** — The `NETWORK` environment variable selects which chain and network to run (`leios` → Musashi Dojo, magic 164)
4. **Operator-Focused** — Designed for stake pool operators running production infrastructure
5. **Kubernetes-Native** — First-class K3s/K8s support with Helm charts and raw manifests
6. **No Ambiguous Tags** — Images are tagged `<chain>-<version>`, never just `latest`
7. **Version Isolation** — Cardano and ApexFusion can run different node versions without conflict
