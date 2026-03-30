# Midnight Chain Module

This directory contains Midnight network configurations and deployment manifests for the [Hybrid-Node](../../README.md) platform.

[Midnight](https://midnight.network/) is a data-protection blockchain developed by [IOG (Input Output)](https://iog.io/), built on Substrate with a partner chains bridge to Cardano. It provides confidential smart contracts using zero-knowledge proofs while leveraging Cardano's security through a sidechain consensus mechanism.

> 🟢 **Production-validated** — Running VOLCY and SILEM validator nodes on Midnight preview.

---

## Supported Networks

| Network | `CFG_PRESET=` | Cardano Sidechain | Status |
|---------|---------------|-------------------|--------|
| Preview | `preview` | Cardano Preview | ✅ Production |

---

## Architecture

Unlike Cardano and ApexFusion, Midnight uses its **own binary** (`midnight-node`, a Substrate-based node) rather than `cardano-node`. However, it requires a companion Cardano node for the partner chains bridge that anchors Midnight's consensus to Cardano's security.

```
┌──────────────────────────────────────────────────────┐
│                  Midnight Stack                       │
│                                                       │
│   ┌───────────────────────────────────────────────┐   │
│   │            midnight-node (Substrate)           │   │
│   │  • Partner Chains sidechain consensus          │   │
│   │  • Zero-knowledge proof execution              │   │
│   │  • Confidential smart contracts (Compact)      │   │
│   │  • libp2p networking (WebSocket transport)     │   │
│   └───────────────────────┬───────────────────────┘   │
│                           │                           │
│   ┌───────────────────────┴───────────────────────┐   │
│   │         Cardano Node (Preview)                 │   │
│   │  • Anchors sidechain blocks to Cardano         │   │
│   │  • Provides SPO registration data              │   │
│   │  • Runs as companion service                   │   │
│   └───────────────────────────────────────────────┘   │
│                                                       │
│   ┌─────────┐  ┌──────────┐  ┌──────────────────┐   │
│   │Postgres │  │ DB-Sync  │  │ Ogmios (optional)│   │
│   └─────────┘  └──────────┘  └──────────────────┘   │
└──────────────────────────────────────────────────────┘
```

---

## Key Differences from Cardano/ApexFusion

| Feature | Cardano / ApexFusion | Midnight |
|---------|---------------------|----------|
| Node binary | `cardano-node` (shared) | `midnight-node` (Substrate-based) |
| Docker image | `ghcr.io/gvolcy/hybrid-node` | `midnightntwrk/midnight-node` |
| Consensus | Ouroboros (Praos/Genesis) | Partner Chains (Substrate + Cardano anchor) |
| Networking | Ouroboros P2P | libp2p (WebSocket transport) |
| Ports | 3001/6000 (P2P) | 30333 (P2P), 9944 (RPC), 9615 (Prometheus) |
| Companion services | None | Cardano node + Postgres + DB-Sync |
| Validator keys | VRF/KES/cold keys (file-based) | AURA/GRANDPA/Sidechain keys (RPC-inserted) |
| Mithril | ✅ Available | ❌ Not applicable |
| Guild Operators | ✅ CNTools, gLiveView | ❌ Not applicable |

---

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| `midnight-node` | 0.22.3 | [midnightntwrk/midnight-node](https://hub.docker.com/r/midnightntwrk/midnight-node) |
| `cardano-node` (companion) | 10.6.2 | [intersectmbo/cardano-node](https://github.com/IntersectMBO/cardano-node) |
| `cardano-db-sync` | 13.6.0.7 | [intersectmbo/cardano-db-sync](https://github.com/IntersectMBO/cardano-db-sync) |
| `ogmios` | v6.14.0 | [cardanosolutions/ogmios](https://github.com/CardanoSolutions/ogmios) |
| `postgres` | 15.3 | [postgres](https://hub.docker.com/_/postgres) |

---

## Structure

```
midnight/
├── README.md
├── configs/
│   └── preview/           # Preview network configuration
│       └── .gitkeep
└── k3s/
    ├── namespace.yaml     # Namespace + Postgres + Secrets template
    ├── cardano-stack.yaml # Cardano node + DB-Sync + Ogmios
    └── midnight-node.yaml # Midnight validator node + key-inserter sidecar
```

---

## Prerequisites

Midnight nodes require the following companion services, deployed **in order**:

1. **Postgres** — Database for Cardano DB-Sync
2. **Cardano Node** — Preview network full node (partner chains bridge)
3. **Cardano DB-Sync** — Indexes Cardano blocks for Midnight's cross-chain reads
4. **Ogmios** (optional) — WebSocket bridge to Cardano node

---

## Quick Start (K3s)

### 1. Create namespace and secrets

Edit `k3s/namespace.yaml` — replace placeholder keys with your validator keys:

```bash
kubectl apply -f chains/midnight/k3s/namespace.yaml
```

### 2. Deploy the Cardano companion stack

```bash
kubectl apply -f chains/midnight/k3s/cardano-stack.yaml
```

Wait for the Cardano node to sync to tip before proceeding.

### 3. Deploy the Midnight node

```bash
kubectl apply -f chains/midnight/k3s/midnight-node.yaml
```

### Verify

```bash
# Check pods
kubectl get pods -n midnight

# Check Midnight node sync status
kubectl logs -n midnight deployment/midnight-node -c midnight-node --tail 5

# Check peer count and sync
kubectl exec -n midnight deployment/midnight-node -c key-inserter -- \
  curl -s -X POST -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"system_health","params":[]}' \
  http://127.0.0.1:9944
```

---

## Environment Variables

### Midnight Node

| Variable | Default | Description |
|----------|---------|-------------|
| `CFG_PRESET` | — | `preview` |
| `NODE_KEY` | — | libp2p node private key (hex) |
| `BOOTNODES` | — | Space-separated multiaddr boot nodes |
| `APPEND_ARGS` | — | Additional CLI flags (e.g., `--validator`, `--name`) |
| `DB_SYNC_POSTGRES_CONNECTION_STRING` | — | PostgreSQL connection string |
| `CARDANO_SECURITY_PARAMETER` | `432` | Cardano `k` parameter |
| `CARDANO_ACTIVE_SLOTS_COEFF` | `0.05` | Cardano active slots coefficient |
| `BLOCK_STABILITY_MARGIN` | `0` | Block stability margin |

### Validator Keys (inserted via RPC sidecar)

| Variable | Description |
|----------|-------------|
| `AURA_PUB_KEY` | AURA consensus public key (hex, `0x` prefix) |
| `GRANDPA_PUB_KEY` | GRANDPA finality public key (hex, `0x` prefix) |
| `SIDECHAIN_PUB_KEY` | Partner Chains sidechain public key (hex, `0x` prefix) |

> ⚠️ Midnight validator keys are **inserted via RPC** after the node starts, not loaded from files. The key-inserter sidecar handles this automatically and re-checks hourly.

---

## Operational Notes

### Validator vs Full Node

- Setting `--validator` in `APPEND_ARGS` enables block production (Role: AUTHORITY).
- Without `--validator`, the node runs as a full node (Role: FULL).
- Validator keys (AURA, GRANDPA, Sidechain) must be inserted via RPC.

### Peer Discovery

- Midnight uses **libp2p** for peer discovery (not Ouroboros P2P).
- Boot nodes are configured via the `BOOTNODES` environment variable.
- Nodes behind NAT may have limited inbound peer connections.
- Port 30333 (P2P) should be exposed for optimal connectivity.

### Key Insertion

- Validator keys are inserted via the Substrate `author_insertKey` RPC method.
- The key-inserter sidecar waits for RPC readiness, inserts all three key types, then monitors hourly.
- Keys persist in the node's keystore at `/node/chain/chains/midnight_preview/keystore/`.

### Cardano Companion Node

- Midnight requires a fully synced Cardano Preview node.
- DB-Sync must be running and synced for the partner chains bridge.
- If Cardano falls behind, Midnight will log: `Unable to author block — No latest block on chain`.

### Boot Nodes (Preview Network)

```
/dns/bootnode-1.preview.midnight.network/tcp/30333/ws/p2p/12D3KooWK66i7dtGVNSwDh9tTeqov1q6LSdWsRLJvTyzTCaywYgK
/dns/bootnode-2.preview.midnight.network/tcp/30333/ws/p2p/12D3KooWHqFfXFwb7WW4jwR8pr4BEf562v5M6c8K3CXAJq4Wx6ym
```

---

## Upstream Resources

| Resource | Link |
|----------|------|
| Midnight Network | [midnight.network](https://midnight.network/) |
| Midnight Docs | [docs.midnight.network](https://docs.midnight.network/) |
| Node Docker Repo | [midnightntwrk/midnight-node-docker](https://github.com/midnightntwrk/midnight-node-docker) |
| Docker Hub | [midnightntwrk/midnight-node](https://hub.docker.com/r/midnightntwrk/midnight-node) |
| Midnight Discord | [discord.gg/midnightnetwork](https://discord.com/invite/midnightnetwork) |

---

## Credits

- [Midnight Foundation](https://github.com/midnightntwrk) — Midnight node and tooling (Apache 2.0)
- [IOG / Input Output](https://iog.io/) — Partner Chains framework
- [IntersectMBO](https://github.com/IntersectMBO/cardano-node) — Companion Cardano node
- [Parity / Substrate](https://substrate.io/) — Substrate framework
