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
| `midnight-node` | 1.0.400 | [midnightntwrk/midnight-node](https://hub.docker.com/r/midnightntwrk/midnight-node) |
| `cardano-node` (companion) | 11.0.1 | [intersectmbo/cardano-node](https://github.com/IntersectMBO/cardano-node) |
| `cardano-db-sync` | 13.7.0.5 | [intersectmbo/cardano-db-sync](https://github.com/IntersectMBO/cardano-db-sync) |
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
| `NODE_KEY` | — | Stored in the secret for reference only. The binary does **not** use this env for identity. |
| `BOOTNODES` | — | Space-separated multiaddr boot nodes (also reference-only; pass `--bootnodes` in `APPEND_ARGS`) |
| `APPEND_ARGS` | — | CLI flags. Must include `--bootnodes`, `--sync warp`, and `--node-key <64-hex>` for a stable peer id. |
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
| `AURA_SEED` / `GRANDPA_SEED` / `SIDECHAIN_SEED` | Secret seeds for `author_insertKey` (keep in the Kubernetes secret, not the ConfigMap) |

> ⚠️ Midnight keys are **inserted via RPC** after the node starts. Pass seed + public key to `author_insertKey`. The sidechain key type is `crch` (ECDSA), not a copy of the AURA key. The key-inserter sidecar re-checks hourly.

---

## Operational Notes

### Validator vs Full Node

- Setting `--validator` in `APPEND_ARGS` enables block production (Role: AUTHORITY).
- Without `--validator`, the node runs as a full node (Role: FULL).
- Preview currently has **0 registered stake-pool seats** (`numRegisteredCandidates: 0`).
  Keep VOLCY/SILEM as full nodes until Mōhalu opens registered seats. Do not register
  or enable `--validator` just to "test" the node.
- Validator keys (AURA, GRANDPA, Sidechain) must be inserted via RPC.

### Peer identity (`--node-key`)

- The `NODE_KEY` environment variable does **not** set the libp2p peer id.
- Put a 64-character hex key in `APPEND_ARGS` as `--node-key <hex>` (no `0x` prefix).
- Keep the same value in the `midnight-secrets` `node-key` entry so backups and the
  live flag stay aligned.
- If public peers refuse block requests after a stall and the node sits on one height,
  rotate `--node-key`. Wiping the chain alone does not clear a blacklisted peer id.

### Peer Discovery

- Midnight uses **libp2p** for peer discovery (not Ouroboros P2P).
- Pass bootnodes with `--bootnodes` in `APPEND_ARGS` (the `BOOTNODES` env is ignored by the binary).
- Nodes behind NAT need the P2P NodePort forwarded and `--public-addr` set to the public multiaddr.
- Keep RPC `9944` and metrics `9615` as ClusterIP.
- Prefer `--sync warp` in `APPEND_ARGS` for faster catch-up after wipes/restarts.
- Running two nodes (e.g. separate namespaces on one cluster): add
  `--reserved-nodes /dns/midnight-p2p.<peer-ns>.svc.cluster.local/tcp/30333/ws/p2p/<PEER_ID>`
  so the pair stays dialed after peer bans or restarts. Get `PEER_ID` via
  `system_localPeerId` RPC on the peer node.

### Unclean shutdown / ledger corruption

After a host crash or hard kill, the Midnight ledger DB can be left inconsistent.
Symptoms:

- Local tip stuck while public Preview advances
- Sync rate `0.0 bps`
- Logs: `root should be in the arena` / `not in storage arena`
- Peers connect, then get banned for `Same block request multiple times`

Recovery (keep identity and signing keys):

1. Scale the `midnight-node` Deployment to `0`.
2. On the PVC host path, delete only:
   - `chain/chains/midnight_preview/paritydb`
   - `chain/chains/midnight_preview/network`
   - `chain/ledger_storage`
3. Leave `chain/chains/midnight_preview/keystore/` untouched.
4. Scale back to `1` with `--sync warp` still in `APPEND_ARGS`.
5. Confirm tip vs `https://rpc.preview.midnight.network/`.

Do **not** delete the keystore or change `--node-key` for this recovery unless peers
are also blacklisting the identity.

### Postgres `/dev/shm`

- The k3s/Helm manifests mount a 1Gi `emptyDir` (Memory) at `/dev/shm`.
- Without this, Postgres can fail with `No space left on device` when resizing
  shared memory (default container shm is 64Mi), which stalls db-sync and the
  Midnight partner-chain data source.

### Key Insertion

- Keys are inserted via the Substrate `author_insertKey` RPC method: type, seed, public.
- Types: `aura` (sr25519), `gran` (ed25519), `crch` (ECDSA compressed, 33-byte / `0x02`/`0x03`).
- Keep seeds in the Kubernetes secret. Do not put seed phrases in the key-inserter ConfigMap.
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
