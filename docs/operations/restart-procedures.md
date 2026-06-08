# Restart Procedures

## Graceful Restart (Preferred)

The entrypoint traps SIGTERM and sends SIGINT to cardano-node so it flushes its
ledger DB and exits cleanly. Always use graceful stops.

```bash
# Stop with a 600s timeout (entrypoint waits up to 540s for a clean node exit)
docker stop -t 600 cardano-relay

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

# Re-launch — the node replays from its last on-disk ledger state
docker run -d --name cardano-relay ... ghcr.io/gvolcy/hybrid-node:cardano-11.0.1
```

**If the DB is corrupted after a force kill:**

```bash
# Option 1: Delete DB and re-sync via Mithril (Cardano only, ~30 min)
rm -rf /opt/cardano/cnode/db/*
docker run -d --name cardano-relay \
  -e NETWORK=mainnet \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-11.0.1

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
