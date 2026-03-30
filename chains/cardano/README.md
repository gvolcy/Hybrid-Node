# Cardano Chain Module

This directory contains Cardano-specific configurations and deployment manifests for the [Hybrid-Node](../../README.md) platform.

Cardano is a third-generation, proof-of-stake blockchain platform. The [`cardano-node`](https://github.com/IntersectMBO/cardano-node) is the core component used to participate in the Cardano decentralized network — it integrates the [ledger](https://github.com/IntersectMBO/cardano-ledger), [consensus](https://github.com/IntersectMBO/ouroboros-consensus), and [networking](https://github.com/IntersectMBO/ouroboros-network) layers into a single executable.

> 🟢 **Production-validated** — Running VOLCY and SILEM stake pools on Cardano mainnet.

---

## Supported Networks

| Network | Description | Status |
|---------|-------------|--------|
| `mainnet` | Cardano Mainnet | ✅ Production |
| `preprod` | Pre-production testnet | ✅ Supported |
| `preview` | Preview testnet | ✅ Supported |
| `guild` | Guild Operators testnet | ✅ Supported |

---

## Architecture

Hybrid-Node builds `cardano-node` **from source** using the upstream [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) repository, ensuring reproducible, version-pinned binaries.

```
┌─────────────────────────────────────────────────┐
│                 cardano-node                     │
│                                                  │
│   ┌───────────┐ ┌────────────┐ ┌─────────────┐  │
│   │  Ledger   │ │ Consensus  │ │ Networking   │  │
│   │ (Conway)  │ │ (Ouroboros)│ │ (P2P)        │  │
│   └───────────┘ └────────────┘ └─────────────┘  │
│                                                  │
│   ┌───────────────────────────────────────────┐  │
│   │           Guild Operators Tooling          │  │
│   │  CNTools · gLiveView · topologyUpdater     │  │
│   └───────────────────────────────────────────┘  │
│                                                  │
│   ┌────────┐ ┌─────────┐ ┌───────┐ ┌────────┐  │
│   │ CNCLI  │ │ Mithril │ │ nview │ │ txtop  │  │
│   └────────┘ └─────────┘ └───────┘ └────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Component Versions

| Component | Version | Source |
|-----------|---------|--------|
| `cardano-node` | Source-built from tag | [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) |
| `cardano-cli` | Downloaded binary | [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) |
| Guild Scripts | CNTools, gLiveView, env | [cardano-community/guild-operators](https://github.com/cardano-community/guild-operators) |
| CNCLI | Slot leader logs, validation | [cardano-community/cncli](https://github.com/cardano-community/cncli) |
| Mithril | Client (fast sync) + Signer | [input-output-hk/mithril](https://github.com/input-output-hk/mithril) |
| nview | TUI node monitor | [blinklabs-io/nview](https://github.com/blinklabs-io/nview) |
| txtop | Mempool display | [blinklabs-io/txtop](https://github.com/blinklabs-io/txtop) |

> The node version is controlled by the `NODE_VERSION` build arg in [`platform/docker/Dockerfile`](../../platform/docker/Dockerfile).

---

## System Requirements

From the upstream [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases):

| Resource | Minimum | Recommended (SPO) |
|----------|---------|--------------------|
| CPU | 2 cores @ 1.6 GHz | 2+ cores @ 2 GHz |
| RAM (`InMemory` backend) | 24 GB | 24 GB |
| RAM (`OnDisk` backend) | 8 GB | 8 GB |
| Storage | 300 GB | 350 GB (for growth) |
| Architecture | x86_64, ARM64 | x86_64, ARM64 |

---

## Structure

```
cardano/
├── README.md
├── configs/           # Network config overrides (per-network subdirectories)
│   ├── mainnet/
│   ├── preprod/
│   ├── preview/
│   └── guild/
└── k3s/               # Kubernetes manifests
    ├── bp.yaml         # Block producer deployment
    └── relay.yaml      # Relay deployment
```

---

## Quick Start

### Docker — Relay

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

### Docker — Block Producer

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
  ghcr.io/gvolcy/hybrid-node:latest
```

### Kubernetes (K3s)

```bash
kubectl apply -f chains/cardano/k3s/relay.yaml
kubectl apply -f chains/cardano/k3s/bp.yaml
```

---

## Environment Variables

### Core

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | `mainnet`, `preprod`, `preview`, `guild` |
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
| `MITHRIL_SIGNER` | `N` | Enable Mithril signer |

### Monitoring

| Variable | Default | Description |
|----------|---------|-------------|
| `PROMETHEUS_HOST` | `0.0.0.0` | Prometheus listen address |
| `PROMETHEUS_PORT` | `12798` | Prometheus metrics port |
| `EKG_HOST` | `0.0.0.0` | EKG listen address |

---

## Operational Notes

### P2P Networking
- Cardano uses **Ouroboros P2P** for peer discovery and connection management.
- Non-P2P mode has been removed as of cardano-node 10.6.0.
- BPs should have `PeerSharing` **disabled** to avoid leaking their IP.
- Relays should run with `PeerSharing` enabled (default).
- Consider running at least one relay in `GenesisMode` for Ouroboros Genesis support.

### BP Topology Lock-down
- BPs should **only** connect to your own relays via `CUSTOM_PEERS`.
- In BP mode, `CUSTOM_PEERS` replaces the entire topology (no genesis peers added).
- Incoming connections should be restricted via `NetworkPolicy` to relay IPs only.

### Mithril
- **Mithril client**: Enables fast chain sync by downloading a certified snapshot instead of replaying from genesis.
- **Mithril signer**: SPOs can participate in the Mithril signing protocol (set `MITHRIL_SIGNER=Y`).

### CNCLI
- Slot leader log prediction for upcoming epochs.
- Block validation and PoolTool reporting.
- Requires `POOL_ID` and `POOL_TICKER` env vars for full functionality.

### Graceful Shutdown
- The entrypoint handles `SIGINT`/`SIGTERM` with a **280-second drain** to ensure clean shutdown.
- Kubernetes `terminationGracePeriodSeconds` should be set to ≥ 300.

---

## Upstream Documentation

| Resource | Link |
|----------|------|
| Cardano Node Documentation | [docs.cardano.org](https://docs.cardano.org/cardano-components/cardano-node) |
| Cardano Developer Portal | [developers.cardano.org](https://developers.cardano.org/docs/get-started/) |
| P2P & Topology | [Topology Guide](https://developers.cardano.org/docs/operate-a-stake-pool/node-operations/topology) |
| UTxO-HD Configuration | [Consensus Docs](https://ouroboros-consensus.cardano.intersectmbo.org/docs/references/miscellaneous/utxo-hd/) |
| Compatibility Matrix | [Release Notes](https://docs.cardano.org/developer-resources/release-notes/comp-matrix) |
| Ledger API Docs | [cardano-ledger](https://cardano-ledger.cardano.intersectmbo.org/) |
| Consensus API Docs | [ouroboros-consensus](https://ouroboros-consensus.cardano.intersectmbo.org/haddocks/) |
| Network API Docs | [ouroboros-network](https://ouroboros-network.cardano.intersectmbo.org/) |
| Guild Operators Docs | [cardano-community.github.io](https://cardano-community.github.io/guild-operators/) |
| CoinCashew SPO Guide | [coincashew.com](https://www.coincashew.com/coins/overview-ada/guide-how-to-build-a-haskell-stakepool-node) |

---

## Upstream Releases

The latest upstream `cardano-node` releases from [IntersectMBO](https://github.com/IntersectMBO/cardano-node/releases):

| Version | Date | Notes |
|---------|------|-------|
| **10.7.0** | Mar 2026 | LSM Tree backend (8GB RAM), KES Agent, cardano-rpc (gRPC), `behindFirewall` peer config. **Latest stable.** Requires full chain replay. |
| **10.6.2** | Feb 2026 | Plutus V4 features, mempool hardening, ARM64 OCI images. |
| **10.5.4** | Feb 2026 | Networking robustness, preview genesis checkpoint, SPO upgrade recommended. |
| **10.4.1** | Apr 2025 | UTxO-HD integration (InMemory + LMDB backends). |

> ⚠️ Hybrid-Node currently builds from the version specified in `NODE_VERSION`. Update the Dockerfile build arg to track new upstream releases.

---

## Credits

- [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node) — The core node (Apache 2.0)
- [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli) — CLI tooling
- [Guild Operators](https://github.com/cardano-community/guild-operators) — CNTools, gLiveView, topologyUpdater (MIT)
- [CNCLI](https://github.com/cardano-community/cncli) — Leader logs and validation
- [Mithril](https://github.com/input-output-hk/mithril) — Fast sync and SPO signing
- [Blink Labs](https://github.com/blinklabs-io) — nview, txtop monitoring tools
- [CoinCashew](https://www.coincashew.com/) — SPO best practices
