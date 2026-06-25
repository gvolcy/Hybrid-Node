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
│  │             │  │ Leios       │  │ Leios       │  │ Leios       │  │
│  │ VOLCY Pool  │  │ leiosT1     │  │ leiosT2     │  │ leiosT3     │  │
│  │ SILEM Pool  │  │ Discord     │  │             │  │ (pending)   │  │
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
│  │ Leios BPs   │  │             │                                    │
│  │ leios-volcy │  │             │                                    │
│  │ leios-silem │  │             │                                    │
│  └─────────────┘  └─────────────┘                                    │
└─────────────────────────────────────────────────────────────────────────┘
```

### Host Roles

| Host | Role | Networks | Notes |
|------|------|----------|-------|
| **main1** | Block Producers | Cardano mainnet, ApexFusion afpm | VOLCY + SILEM pools. Locked down — no public ports. |
| **main2** | Testnet / Dev | Preview, Preprod, Guild, AFPT, Midnight, **Leios BPs** | Non-production workloads. **leios-volcy** + **leios-silem** (Hybrid-Node image, private topology). |
| **main3** | Relays + K3s | Cardano mainnet, ApexFusion afpm, **Leios leiosT1** | Primary relay. K3s cluster (Discord bots, **leiosT1** relay on :3010). |
| **main4** | Relays | Cardano mainnet, ApexFusion afpm, **Leios leiosT2** | Secondary Leios relay (:3010) for BP peering redundancy. |
| **main5** | Relays + AI | Cardano mainnet, Leios (**leiosT3**, pending) | Tertiary Leios relay when host is online. AI sandbox (Ollama). |
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
├── Leios (Ouroboros Leios — Musashi Dojo)
│   └── musashi (leios, magic 164) → Option B: ghcr.io/gvolcy/hybrid-node:leios-11.0.1
│       Relays: leiosT1 (main3 :3010), leiosT2 (main4 :3010), leiosT3 (main5, pending)
│       BPs: leios-volcy (main2 :6000), leios-silem (main2 :6001)
│       Fleet node pin: git 40888f50 (chain-db compatible); HEAD CLI for Dijkstra txs
│       On-chain: stake + pool registered; forging pending upstream BLS (#776)
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
>
> **Fleet pin:** `chains/leios/versions.env` sets `NODE_BUILD_REF=40888f50` so running
> nodes stay chain-db compatible with the IOG prebuilt binary. Override at build time for
> newer CLI features (e.g. `make build-leios NODE_BUILD_REF=7c357a55` for Dijkstra cert/tx
> fixes); use one-shot pods for cert/tx work without upgrading the syncing fleet node.

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

### Fleet topology (deployed)

All live Leios nodes run **Option B** — `ghcr.io/gvolcy/hybrid-node:leios-11.0.1` with
`NETWORK=leios` and the shared entrypoint. Relays bootstrap from IOG's Musashi peer;
BPs use a **private topology** (Tailscale only, no public or ledger peers).

```
Internet / Musashi bootstrap
         │
         │  leios-node.play.dev.cardano.org:3001
         ▼
┌─────────────────────────────────────────────────────────────────┐
│  Relay layer (public :3010, Hybrid-Node image)                  │
│                                                                 │
│   main3: leiosT1 (leiost1)          main4: leiosT2 (leiost2)   │
│   Tailscale 100.103.135.9:3010      Tailscale 100.110.37.42:3010│
└───────────────┬─────────────────────────────┬───────────────────┘
                │         Tailscale mesh        │
                ▼                               ▼
┌─────────────────────────────────────────────────────────────────┐
│  main2 — Block producers (private :6000 / :6001, NO public ports)│
│                                                                 │
│   leios-volcy (:6000)              leios-silem (:6001)          │
│   CUSTOM_PEERS → leiosT1 + leiosT2 only                        │
│   Keys: /data/leios/<pool>/priv    Wallet: /data/leios/<pool>/wallet│
└─────────────────────────────────────────────────────────────────┘
```

| Node | Role | Host | Namespace | Port | Image |
|------|------|------|-----------|------|-------|
| `leiosT1` | relay | main3 | `leiost1` | 3010 | `hybrid-node:leios-11.0.1` |
| `leiosT2` | relay | main4 | `leiost2` | 3010 | `hybrid-node:leios-11.0.1` |
| `leiosT3` | relay | main5 | `leiost3` | 3010 | pending (host offline) |
| `leios-volcy` | BP | main2 | `leios-volcy` | 6000 | `hybrid-node:leios-11.0.1` |
| `leios-silem` | BP | main2 | `leios-silem` | 6001 | `hybrid-node:leios-11.0.1` |

K3s manifests: `chains/leios/k3s/leiost1.yaml`, `leiost2.yaml`, `main2/leios-volcy.yaml`,
`main2/leios-silem.yaml`.

**Option A** (IOG prebuilt `ghcr.io/input-output-hk/ouroboros-leios/cardano-node-testnet:latest`)
remains documented for quick relay smoke tests but is **not** what the fleet runs.

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
- **Force-refreshes** `topology.json` on every start — guild-deploy seeds a Cardano
  *mainnet* topology by default, which is wrong for Musashi Dojo
- Maps `--testnet-magic 164` / `CARDANO_NODE_NETWORK_ID=164` for CLI queries
- Skips Mithril (unavailable for Leios)
- BP mode: loads KES/VRF/op.cert from `kes.skey` + `vrf.skey` + `op.cert` naming
  (in addition to CoinCashew `node.cert` / `hot.skey` layouts)
- `CUSTOM_PEERS` on BPs replaces topology with relay-only Tailscale peers
- BP forging deferred until BLS key support lands upstream

### On-chain operator status (Musashi)

| Step | Status |
|------|--------|
| Stake address registration | ✅ both pools (Dijkstra era txs via HEAD CLI) |
| Pool registration | ✅ both pools (500 ADA deposit each) |
| Pool params (5k pledge, 3% margin, relays) | queued in `futurePoolParams` until next epoch |
| Pool delegation (faucet) | ❌ pending — needed to satisfy pledge |
| BLS in pool cert + node `--shelley-bls-key` | ❌ pending ([ouroboros-leios#776](https://github.com/input-output-hk/ouroboros-leios/issues/776)) |

### Image build

```bash
# Default fleet-compatible build (matches IOG prebuilt chain DB):
make build-leios NODE_BUILD_REF=40888f50725e473d91f40e554e2d436dfc80a924

# HEAD build (Dijkstra cert/tx fixes — for one-shot CLI pods, not fleet node DB):
make build-leios NODE_BUILD_REF=7c357a5531cc3316e9f708f4465eb66db564d8aa

# Override repo if upstream moves the prototype branch:
make build-leios \
  NODE_REPO=https://github.com/IntersectMBO/cardano-node.git \
  NODE_BUILD_REF=leios-prototype
```

`Dockerfile.leios` clones `leios-prototype` (depth 50) then checks out `NODE_BUILD_REF`
when it differs from the branch name.

---

## Port Map

### Leios / Musashi Dojo

| Service | Port | Protocol | Notes |
|---------|------|----------|-------|
| cardano-node (relay) | 3010 | TCP | **leiosT1/leiosT2** — public + Musashi bootstrap |
| cardano-node (BP) | 6000 / 6001 | TCP | **leios-volcy / leios-silem** — private, relay-only via Tailscale |
| Prometheus metrics | 12798 | HTTP | Internal only |
| EKG | 12788 | HTTP | Internal only |
| Leios DB | — | SQLite | `leios.db` inside `db/` (endorser-block tx store) |
| Node socket | — | Unix | `/opt/cardano/cnode/sockets/node.socket` |
| Host data (K3s) | — | hostPath | `/data/leios/<node>/` — `data/`, `priv/`, `wallet/` |

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
