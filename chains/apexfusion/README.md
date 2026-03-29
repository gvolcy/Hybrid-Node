# ApexFusion Chain Module

This directory contains ApexFusion Vector chain configurations and deployment manifests for the [Hybrid-Node](../../README.md) platform.

[ApexFusion](https://apexfusion.org/) is a multi-chain blockchain platform built on Cardano's Ouroboros consensus. It uses the same `cardano-node` binary as Cardano but with its own genesis files, network topology, and governance. The ApexFusion Vector chain provides a separate execution environment while maintaining compatibility with Cardano's proven infrastructure.

> 🟢 **Production-validated** — Running AFPM and AFPT block producers across 5 servers (9 BPs, 6 relays).

---

## Supported Networks

| Network | Description | Port (typical) | Status |
|---------|-------------|----------------|--------|
| `afpm` | ApexFusion Prime Mainnet | 4550–4554 | ✅ Production |
| `afpt` | ApexFusion Prime Testnet | 3535, 3434, 3737 | ✅ Production |

---

## Architecture

ApexFusion shares the same `cardano-node` binary as Cardano — the chain separation happens at the **genesis and configuration layer**, not the binary layer.

```
┌──────────────────────────────────────────────────┐
│               cardano-node (shared)               │
│                                                   │
│   ┌─────────────────────────────────────────────┐ │
│   │      ApexFusion Genesis & Config Files       │ │
│   │  afpm: shelley-genesis, byron-genesis, etc.  │ │
│   │  afpt: shelley-genesis, byron-genesis, etc.  │ │
│   └─────────────────────────────────────────────┘ │
│                                                   │
│   ┌───────────────────────────────────────────┐   │
│   │     Guild Operators (APEX Fork)            │   │
│   │  CNTools · gLiveView · topologyUpdater     │   │
│   └───────────────────────────────────────────┘   │
│                                                   │
│   ┌────────┐            ┌───────┐ ┌────────┐     │
│   │ CNCLI  │            │ nview │ │ txtop  │     │
│   └────────┘            └───────┘ └────────┘     │
│                                                   │
│   ⚠ Mithril: NOT AVAILABLE on ApexFusion          │
└──────────────────────────────────────────────────┘
```

---

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| `cardano-node` | 10.1.4 | [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) |
| `cardano-cli` | 9.4.1.0 | [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) |
| Guild Scripts | APEX fork | [Scitz0/guild-operators-apex](https://github.com/Scitz0/guild-operators-apex) (`main` branch) |
| CNCLI | 6.7.0 | [cardano-community/cncli](https://github.com/cardano-community/cncli) |
| nview | Latest | [blinklabs-io/nview](https://github.com/blinklabs-io/nview) |
| txtop | Latest | [blinklabs-io/txtop](https://github.com/blinklabs-io/txtop) |

> ⚠️ ApexFusion requires **specific node and CLI versions** that are compatible with the network's current hard fork era. These may differ from the latest upstream Cardano releases.

---

## Key Differences from Cardano

| Feature | Cardano | ApexFusion |
|---------|---------|------------|
| Genesis files | Cardano-specific | ApexFusion-specific (downloaded by Guild scripts) |
| Guild scripts source | `cardano-community/guild-operators` | `Scitz0/guild-operators-apex` (fork) |
| Mithril | ✅ Client + Signer | ❌ Not available |
| Node version | Tracks latest upstream | Pinned to ApexFusion-compatible version |
| CLI version | Tracks latest upstream | Pinned (9.4.1.0 required by APEX Guild scripts) |
| P2P networking | Full P2P with Genesis mode | P2P (network-specific topology) |
| PoolTool integration | ✅ Available | Network-specific |

---

## Structure

```
apexfusion/
├── README.md
├── configs/           # Network config overrides (per-network subdirectories)
│   ├── afpm/          # ApexFusion Prime Mainnet
│   └── afpt/          # ApexFusion Prime Testnet
└── k3s/               # Kubernetes manifests
    ├── bp.yaml         # Block producer deployment
    ├── relay.yaml      # Relay deployment (mainnet)
    └── testnet-relay.yaml  # Testnet relay deployment
```

---

## Quick Start

### Docker — Relay (Mainnet)

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

### Docker — Block Producer

```bash
docker run -d \
  --name apex-bp \
  -e NETWORK=afpm \
  -e NODE_MODE=bp \
  -e NODE_PORT=8784 \
  -e POOL_NAME=MYPOOL \
  -e CNCLI_ENABLED=Y \
  -e MITHRIL_SIGNER=N \
  -e MITHRIL_DOWNLOAD=N \
  -v apex-db:/opt/cardano/cnode/db \
  -v apex-keys:/opt/cardano/cnode/priv \
  -p 8784:8784 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### Docker — Relay (Testnet)

```bash
docker run -d \
  --name apex-testnet-relay \
  -e NETWORK=afpt \
  -e NODE_MODE=relay \
  -e NODE_PORT=3535 \
  -v apex-testnet-db:/opt/cardano/cnode/db \
  -p 3535:3535 \
  ghcr.io/gvolcy/hybrid-node:latest
```

### Kubernetes (K3s)

```bash
# Mainnet relay
kubectl apply -f chains/apexfusion/k3s/relay.yaml

# Testnet relay
kubectl apply -f chains/apexfusion/k3s/testnet-relay.yaml

# Block producer
kubectl apply -f chains/apexfusion/k3s/bp.yaml
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | — | `afpm` (mainnet) or `afpt` (testnet) |
| `NODE_MODE` | `relay` | `relay` or `bp` |
| `NODE_PORT` | `6000` | Node listening port |
| `CUSTOM_PEERS` | — | Additional peers: `addr:port,addr:port,...` |
| `POOL_NAME` | — | Pool name (BP mode) |
| `CNCLI_ENABLED` | `N` | Enable CNCLI sync / leaderlog |
| `MITHRIL_SIGNER` | `N` | **Must be `N`** — Mithril not available |
| `MITHRIL_DOWNLOAD` | — | **Must be `N`** — Mithril not available |

---

## Operational Notes

### BP Topology Lock-down
- BPs should **only** connect to your own relays via `CUSTOM_PEERS`.
- In BP mode, `CUSTOM_PEERS` replaces the entire topology (strict mode).
- No genesis Tier 2 peers are added — BPs see only your relays.

### Graceful Shutdown
- 280-second `SIGINT` drain ensures clean shutdown.
- Set `terminationGracePeriodSeconds: 300` in K3s manifests.

### Guild Scripts (APEX Fork)
- The Guild Operators scripts used for ApexFusion come from the [Scitz0/guild-operators-apex](https://github.com/Scitz0/guild-operators-apex) fork.
- This fork adapts CNTools, gLiveView, and related scripts for the APEX network's genesis files and configuration.
- The `main` branch is used (not `alpha`).

### Version Pinning
- ApexFusion compatibility is tied to specific `cardano-node` and `cardano-cli` versions.
- Do **not** blindly upgrade to the latest upstream Cardano node — verify ApexFusion compatibility first.
- Current pinned versions: **node 10.1.4**, **CLI 9.4.1.0**.

---

## Upstream Resources

| Resource | Link |
|----------|------|
| ApexFusion Website | [apexfusion.org](https://apexfusion.org/) |
| APEX Guild Scripts | [Scitz0/guild-operators-apex](https://github.com/Scitz0/guild-operators-apex) |
| Guild Operators Docs | [cardano-community.github.io/guild-operators](https://cardano-community.github.io/guild-operators/) |
| Cardano Node (upstream) | [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) |

---

## Credits

- [ApexFusion / Scitz0](https://github.com/Scitz0/guild-operators-apex) — APEX Guild fork (MIT)
- [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) — The core node (Apache 2.0)
- [Guild Operators](https://github.com/cardano-community/guild-operators) — Original tooling (MIT)
- [Blink Labs](https://github.com/blinklabs-io) — nview, txtop monitoring tools
