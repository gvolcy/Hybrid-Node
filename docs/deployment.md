# Deployment Guide

## Prerequisites

- Docker or K3s/Kubernetes cluster
- Persistent storage for blockchain database (300GB+ recommended)
- For BPs: pool keys (hot.skey, vrf.skey, op.cert)

## Docker Deployment

### Cardano Relay
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

### Cardano Block Producer
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

### ApexFusion Relay
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

## Kubernetes (K3s) Deployment

### Using Helm
```bash
# Cardano relay
helm install cardano-relay ./charts/hybrid-node \
  --set cardano.mode=relay \
  --set cardano.network=mainnet

# ApexFusion BP
helm install apex-bp ./charts/hybrid-node \
  --set cardano.mode=bp \
  --set cardano.network=afpm \
  --set pool.name=MYPOOL
```

### Using Raw Manifests
```bash
# Cardano
kubectl apply -f chains/cardano/k3s/relay.yaml
kubectl apply -f chains/cardano/k3s/bp.yaml

# ApexFusion
kubectl apply -f chains/apexfusion/k3s/relay.yaml
kubectl apply -f chains/apexfusion/k3s/bp.yaml
```

## Volume Mounts

| Mount Point | Purpose |
|-------------|---------|
| `/opt/cardano/cnode/db` | Blockchain database |
| `/opt/cardano/cnode/priv` | Pool keys |
| `/opt/cardano/cnode/sockets` | Node socket |
| `/opt/cardano/cnode/guild-db` | CNCLI & Guild databases |
| `/opt/cardano/cnode/mithril` | Mithril signer data |
| `/opt/cardano/cnode/logs` | Node logs |

## Graceful Shutdown

The container uses a 280-second graceful shutdown sequence:
1. K8s preStop hook sends SIGINT
2. Node flushes DB and writes `db/clean` marker
3. Container waits for clean marker (up to 280s)
4. `terminationGracePeriodSeconds: 300` provides headroom
