# Deployment Guide

## Golden Path: Deploy a Cardano Mainnet Relay

This is the simplest path to get a node running.

### Prerequisites

- Docker installed
- 300GB+ disk space for blockchain DB
- 16GB+ RAM recommended

### Step 1: Pull the image

```bash
docker pull ghcr.io/gvolcy/hybrid-node:cardano-11.0.1
```

### Step 2: Run the relay

```bash
docker run -d \
  --name cardano-relay \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  -v cardano-sockets:/opt/cardano/cnode/sockets \
  -p 3001:3001 \
  -p 12798:12798 \
  --restart unless-stopped \
  ghcr.io/gvolcy/hybrid-node:cardano-11.0.1
```

### Step 3: Monitor sync progress

```bash
# Watch logs
docker logs -f cardano-relay

# Or use the health check
scripts/health/check-sync.sh cardano-relay
```

With Mithril enabled, sync takes ~30 minutes. Without it, 12-24 hours.

---

## Deploy Cardano Mainnet Block Producer

### Prerequisites

- At least 2 synced relays
- Pool keys: `kes.skey`, `vrf.skey`, `op.cert`
- Pool registered on-chain

### Step 1: Prepare keys

```bash
# Create key directory
mkdir -p /opt/cardano/cnode/priv/pool/MYPOOL

# Copy keys (from offline/cold storage)
cp kes.skey vrf.skey op.cert /opt/cardano/cnode/priv/pool/MYPOOL/
chmod 400 /opt/cardano/cnode/priv/pool/MYPOOL/*
```

### Step 2: Run the BP

```bash
docker run -d \
  --name cardano-bp \
  -e NETWORK=mainnet \
  -e NODE_MODE=bp \
  -e NODE_PORT=6000 \
  -e POOL_NAME=MYPOOL \
  -e CNCLI_ENABLED=Y \
  -e MITHRIL_SIGNER=Y \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  -v /opt/cardano/cnode/priv:/opt/cardano/cnode/priv \
  -v cardano-sockets:/opt/cardano/cnode/sockets \
  -v cardano-guild-db:/opt/cardano/cnode/guild-db \
  -p 6000:6000 \
  --restart unless-stopped \
  ghcr.io/gvolcy/hybrid-node:cardano-11.0.1
```

> ⚠️ **BP ports should NOT be public.** Only your relays should connect to the BP port.
> Use firewall rules or Kubernetes NetworkPolicy.

---

## Deploy ApexFusion Mainnet Relay

```bash
docker pull ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4

docker run -d \
  --name apex-relay \
  -e NETWORK=afpm \
  -e NODE_MODE=relay \
  -e NODE_PORT=4550 \
  -v apex-db:/opt/cardano/cnode/db \
  -v apex-sockets:/opt/cardano/cnode/sockets \
  -p 4550:4550 \
  -p 12799:12798 \
  --restart unless-stopped \
  ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4
```

> ℹ️ Mithril is not available for ApexFusion. Full sync takes several hours.

---

## Deploy ApexFusion Mainnet Block Producer

```bash
docker run -d \
  --name apex-bp \
  -e NETWORK=afpm \
  -e NODE_MODE=bp \
  -e NODE_PORT=4560 \
  -e POOL_NAME=MYPOOL \
  -e CNCLI_ENABLED=Y \
  -v apex-db:/opt/cardano/cnode/db \
  -v /opt/cardano/cnode/priv:/opt/cardano/cnode/priv \
  -v apex-sockets:/opt/cardano/cnode/sockets \
  -p 4560:4560 \
  --restart unless-stopped \
  ghcr.io/gvolcy/hybrid-node:apexfusion-10.1.4
```

---

## Kubernetes (K3s) Deployment

### Using raw manifests

```bash
# Cardano
kubectl apply -f chains/cardano/k3s/relay.yaml
kubectl apply -f chains/cardano/k3s/bp.yaml

# ApexFusion
kubectl apply -f chains/apexfusion/k3s/relay.yaml
kubectl apply -f chains/apexfusion/k3s/bp.yaml

# Midnight (full stack)
kubectl apply -f chains/midnight/k3s/namespace.yaml
kubectl apply -f chains/midnight/k3s/cardano-stack.yaml
kubectl apply -f chains/midnight/k3s/midnight-node.yaml
```

### Using Helm

```bash
# Cardano relay
helm install cardano-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-relay-example.yaml

# Cardano BP
helm install cardano-bp ./charts/hybrid-node \
  -f charts/hybrid-node/values-bp-example.yaml

# ApexFusion relay
helm install apex-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-apexfusion-relay.yaml

# ApexFusion BP
helm install apex-bp ./charts/hybrid-node \
  -f charts/hybrid-node/values-apexfusion-bp.yaml
```

---

## Volume Mounts

| Mount Point | Purpose | Size |
|-------------|---------|------|
| `/opt/cardano/cnode/db` | Blockchain database | 150-300GB (Cardano), 50GB (ApexFusion) |
| `/opt/cardano/cnode/priv` | Pool keys (BP only) | < 1MB |
| `/opt/cardano/cnode/sockets` | Node socket | < 1MB |
| `/opt/cardano/cnode/guild-db` | CNCLI & Guild databases | 5-10GB |
| `/opt/cardano/cnode/mithril` | Mithril signer data | 1-5GB |
| `/opt/cardano/cnode/logs` | Node logs | 1-5GB |

---

## Graceful Shutdown

Shutdown is handled by the container entrypoint (PID 1), which traps SIGTERM and
forwards SIGINT to cardano-node so it can flush its ledger DB and exit cleanly:

1. K8s sends SIGTERM (or `docker stop`); the entrypoint traps it
2. The entrypoint sends SIGINT to cardano-node, which flushes its in-memory DB
3. CNCLI and mithril-signer helpers are stopped (mithril-signer bounded to 15s)
4. The entrypoint waits for the node to exit (up to 540s; a watchdog SIGKILLs past that)
5. `terminationGracePeriodSeconds: 600` leaves 60s headroom over the 540s cap

No preStop hook is required — the entrypoint receives SIGTERM directly, so the
signal always reaches cardano-node (a clean exit is usually only a few seconds).

```bash
# Use a long timeout for docker stop (≥ the 540s node-drain cap)
docker stop -t 600 cardano-relay
```

---

## Post-Deployment

After deploying, verify everything is healthy:

```bash
# Full health check
scripts/health/check-all.sh <container-name>

# Individual checks
scripts/health/check-sync.sh <container-name>
scripts/health/check-peers.sh <container-name>
scripts/health/check-kes.sh <container-name>    # BP only
scripts/health/check-disk.sh
scripts/health/check-memory.sh <container-name>
```

See also:
- [Upgrade Playbook](operations/upgrade-playbook.md)
- [Restart Procedures](operations/restart-procedures.md)
- [Backup & Restore](operations/backup-restore.md)
- [Incident Response](operations/incident-response.md)
- [Secrets Management](security/secrets.md)
