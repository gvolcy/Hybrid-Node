# ApexFusion Chain Module

This directory contains ApexFusion Vector chain configurations and deployment manifests for the Hybrid-Node platform.

## Supported Networks

| Network | Description | Status |
|---------|-------------|--------|
| `afpm` | ApexFusion Prime Mainnet | ✅ Production |
| `afpt` | ApexFusion Prime Testnet | ✅ Production |

## Structure

```
apexfusion/
├── configs/           # Network config overrides (per-network subdirectories)
│   ├── afpm/          # ApexFusion Prime Mainnet
│   └── afpt/          # ApexFusion Prime Testnet
└── k3s/               # Kubernetes manifests
    ├── bp.yaml         # Block producer deployment
    ├── relay.yaml      # Relay deployment (mainnet)
    └── testnet-relay.yaml  # Testnet relay deployment
```

## Quick Start

```bash
# Run ApexFusion mainnet relay
docker run -d \
  -e NETWORK=afpm \
  -e NODE_MODE=relay \
  -e NODE_PORT=4550 \
  -v apex-db:/opt/cardano/cnode/db \
  -p 4550:4550 \
  ghcr.io/gvolcy/hybrid-node:latest

# Run ApexFusion block producer
docker run -d \
  -e NETWORK=afpm \
  -e NODE_MODE=bp \
  -e NODE_PORT=8784 \
  -e POOL_NAME=MYPOOL \
  -v apex-db:/opt/cardano/cnode/db \
  -v apex-keys:/opt/cardano/cnode/priv \
  -p 8784:8784 \
  ghcr.io/gvolcy/hybrid-node:latest

# K3s deployment
kubectl apply -f chains/apexfusion/k3s/relay.yaml
kubectl apply -f chains/apexfusion/k3s/bp.yaml
```

## Important Notes

- ApexFusion uses the **same cardano-node binary** as Cardano, with different genesis files
- **Mithril is not available** on ApexFusion networks — set `MITHRIL_SIGNER=N` and `MITHRIL_DOWNLOAD=N`
- Guild scripts come from [Scitz0/guild-operators-apex](https://github.com/Scitz0/guild-operators-apex) (ApexFusion fork)
- Current node version: **10.1.4** (ApexFusion-compatible)
- Current CLI version: **9.4.1.0** (required by ApexFusion Guild scripts)
