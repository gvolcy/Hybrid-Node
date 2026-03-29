# Cardano Chain Module

This directory contains Cardano-specific configurations and deployment manifests for the Hybrid-Node platform.

## Supported Networks

| Network | Description | Status |
|---------|-------------|--------|
| `mainnet` | Cardano Mainnet | ✅ Production |
| `preprod` | Pre-production testnet | ✅ Supported |
| `preview` | Preview testnet | ✅ Supported |
| `guild` | Guild Operators testnet | ✅ Supported |

## Structure

```
cardano/
├── configs/           # Network config overrides (per-network subdirectories)
│   ├── mainnet/
│   ├── preprod/
│   ├── preview/
│   └── guild/
└── k3s/               # Kubernetes manifests
    ├── bp.yaml         # Block producer deployment
    └── relay.yaml      # Relay deployment
```

## Quick Start

```bash
# Run Cardano relay
docker run -d \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v cardano-db:/opt/cardano/cnode/db \
  -p 3001:3001 \
  ghcr.io/gvolcy/hybrid-node:latest

# K3s deployment
kubectl apply -f chains/cardano/k3s/relay.yaml
```

## Node Version

The Cardano module currently uses:
- **cardano-node**: Built from [IntersectMBO/cardano-node](https://github.com/IntersectMBO/cardano-node)
- **cardano-cli**: Downloaded from [IntersectMBO/cardano-cli](https://github.com/IntersectMBO/cardano-cli)
- **Guild Scripts**: From [cardano-community/guild-operators](https://github.com/cardano-community/guild-operators)

## Tools

All standard Cardano tooling is available:
- CNTools, gLiveView, topologyUpdater
- CNCLI (slot leader logs, block validation, PoolTool reporting)
- Mithril client (fast sync) and signer (SPO signing)
- nview, txtop (monitoring)
