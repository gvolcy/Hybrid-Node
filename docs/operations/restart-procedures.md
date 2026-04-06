# Restart Procedures

## Graceful Restart (Preferred)

The node writes a clean DB marker on shutdown. Always use graceful stops.

```bash
# Stop with 300s timeout (280s for DB flush + 20s headroom)
docker stop -t 300 cardano-relay

# Start again
docker start cardano-relay
```

### K3s / Kubernetes

```bash
# Rolling restart (graceful)
kubectl rollout restart statefulset/cardano-relay -n cardano

# Watch the rollout
kubectl rollout status statefulset/cardano-relay -n cardano
```

## Emergency Restart

If the node is unresponsive and won't stop gracefully:

```bash
# Force kill (WARNING: may corrupt DB)
docker kill cardano-relay
docker rm cardano-relay

# Re-launch — the node will replay from the last clean marker
docker run -d --name cardano-relay ... ghcr.io/gvolcy/hybrid-node:cardano-10.6.3
```

**If the DB is corrupted after a force kill:**

```bash
# Option 1: Delete DB and re-sync via Mithril (Cardano only, ~30 min)
rm -rf /opt/cardano/cnode/db/*
docker run -d --name cardano-relay \
  -e NETWORK=mainnet \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-10.6.3

# Option 2: Restore from backup (required for ApexFusion)
rsync -avz main6:/backup/apexfusion/afpm/db/ /opt/cardano/cnode/db/
```

## Restart Order

When restarting the entire fleet:

1. **Relays first** (main3, main4, main5) — one at a time
2. **Wait for sync** — verify each relay is synced before starting the next
3. **BP last** (main1) — only after at least 2 relays are synced

```bash
# Verify before moving to next
scripts/health/check-sync.sh cardano-relay
```

## Common Restart Triggers

| Trigger | Action |
|---------|--------|
| OOM kill | Increase memory limit, then restart |
| Disk full | Expand volume or clean old snapshots, then restart |
| Network partition | Check firewall/peers, then restart |
| KES rotation | Restart BP after copying new `op.cert` and `kes.skey` |
| Config change | Stop gracefully, apply change, start |
| Node upgrade | See [upgrade-playbook.md](upgrade-playbook.md) |
