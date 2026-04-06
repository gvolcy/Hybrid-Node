# Rollback Playbook

## When to Roll Back

- New node version fails to sync
- New node version causes missed blocks (BP)
- Incompatible DB format change requires re-sync you can't afford
- Performance regression (memory/CPU/disk I/O)

## Rollback Procedure

### 1. Identify the last known-good image tag

```bash
# Check what was running before
docker images ghcr.io/gvolcy/hybrid-node --format '{{.Tag}} {{.CreatedAt}}' | sort -k2 -r
```

### 2. Stop the current container

```bash
# Graceful stop (280s shutdown for clean DB)
docker stop -t 300 cardano-relay
docker rm cardano-relay
```

### 3. Restore DB backup (if DB format changed)

```bash
# If the new version changed the DB format, restore from backup
rsync -avz main6:/backup/cardano/mainnet/db/ /opt/cardano/cnode/db/

# Or use Mithril to bootstrap fresh
docker run --rm \
  -e NETWORK=mainnet \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-<old-version>
```

### 4. Start with the old image

```bash
docker run -d --name cardano-relay \
  -e NETWORK=mainnet \
  -e NODE_MODE=relay \
  -v cardano-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-<old-version>
```

### 5. Verify

```bash
scripts/health/check-sync.sh cardano-relay
scripts/health/check-peers.sh cardano-relay
```

## Helm Rollback

```bash
# See revision history
helm history cardano-relay

# Roll back to previous revision
helm rollback cardano-relay <revision-number>
```

## Important Notes

- If the DB format changed between versions, you **must** restore a backup or re-sync
- Mithril can re-bootstrap a Cardano node in ~30 minutes vs 12+ hours for a full sync
- Mithril is **not** available for ApexFusion — you must restore from backup or full re-sync
