# Backup & Restore

## What to Back Up

| Data | Path | Frequency | Priority |
|------|------|-----------|----------|
| Pool keys (skey, vrf, op.cert) | `/opt/cardano/cnode/priv/` | On change | 🔴 Critical |
| Blockchain DB | `/opt/cardano/cnode/db/` | Daily | 🟡 Important |
| Guild DB (CNCLI, leaderlog) | `/opt/cardano/cnode/guild-db/` | Weekly | 🟢 Nice to have |
| Mithril signer data | `/opt/cardano/cnode/mithril/` | Weekly | 🟢 Nice to have |
| Node configs (if customized) | `/opt/cardano/cnode/files/` | On change | 🟡 Important |

## Key Backup (Critical — Do This First)

Pool keys are **irreplaceable**. If you lose them, you lose your pool.

```bash
# Backup keys to NAS (encrypted, offline)
rsync -avz --progress \
  /opt/cardano/cnode/priv/pool/ \
  main6:/backup/keys/cardano/$(date +%Y%m%d)/

# Verify the backup
ssh main6 'ls -la /backup/keys/cardano/$(date +%Y%m%d)/'
```

> ⚠️ **Cold keys** should be stored offline on main6 (NAS) and NEVER kept on the BP host
> during normal operation. Only the hot key (`kes.skey`), VRF key (`vrf.skey`), and
> operational certificate (`op.cert`) should be on the BP.

## DB Backup

### Automated DB backup script

```bash
#!/usr/bin/env bash
# Run this from a cron job on the node host

CHAIN="${1:-cardano}"
NETWORK="${2:-mainnet}"
BACKUP_HOST="main6"
BACKUP_DIR="/backup/${CHAIN}/${NETWORK}/db"
DB_PATH="/opt/cardano/cnode/db"
DATE=$(date +%Y%m%d-%H%M)

echo "[${DATE}] Starting DB backup: ${CHAIN}/${NETWORK}"

# Sync DB to NAS
rsync -avz --delete --progress \
  "${DB_PATH}/" \
  "${BACKUP_HOST}:${BACKUP_DIR}/"

echo "[$(date +%Y%m%d-%H%M)] DB backup complete"
```

### Cron schedule

```bash
# Daily DB backup at 3 AM UTC
0 3 * * * /home/mvolcy/Hybrid-Node/scripts/backup-db.sh cardano mainnet >> /var/log/backup-cardano.log 2>&1
0 4 * * * /home/mvolcy/Hybrid-Node/scripts/backup-db.sh apexfusion afpm >> /var/log/backup-apex.log 2>&1
```

## Restore

### From NAS backup

```bash
# Stop the node first
docker stop -t 300 cardano-relay

# Restore DB
rsync -avz --delete main6:/backup/cardano/mainnet/db/ /opt/cardano/cnode/db/

# Restart
docker start cardano-relay
```

### From Mithril snapshot (Cardano only)

```bash
# Delete old DB and bootstrap fresh
rm -rf /opt/cardano/cnode/db/*

docker run -d --name cardano-relay \
  -e NETWORK=mainnet \
  -e MITHRIL_DOWNLOAD=Y \
  -v cardano-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-10.6.3
```

> ℹ️ Mithril bootstrap takes ~30 minutes for Cardano mainnet.
> Mithril is **not available** for ApexFusion — use NAS backup or full re-sync.

## Kubernetes (K3s / Helm)

### Container-managed backup/restore

The chart exposes two flags that let the entrypoint back up or restore the DB on
startup (see [values.yaml](../../charts/hybrid-node/values.yaml) → `cardano.enableBackup` /
`cardano.enableRestore`, wired to `ENABLE_BACKUP` / `ENABLE_RESTORE`):

```yaml
cardano:
  enableBackup: "N"    # set "Y" to snapshot the DB on shutdown/startup
  enableRestore: "N"   # set "Y" to restore from the configured backup on first start
```

> Leave both `"N"` for normal operation. Flip `enableRestore: "Y"` only for a
> one-shot bootstrap, then set it back to avoid restoring on every restart.

### Back up a PVC-backed DB

Prefer a **storage-layer snapshot** (VolumeSnapshot / underlying LVM/ZFS) over a
live file copy — the DB must be quiescent for a consistent file copy.

```bash
# Option A: graceful stop, then snapshot the PVC via your CSI driver
kubectl -n <ns> scale statefulset <name> --replicas=0     # clean shutdown
# ... take a VolumeSnapshot of the DB PVC via your storage class ...
kubectl -n <ns> scale statefulset <name> --replicas=1

# Option B: rsync from the node's hostPath while stopped (K3s single-node)
kubectl -n <ns> scale statefulset <name> --replicas=0
rsync -avz --delete <db-hostpath>/ main6:/backup/cardano/mainnet/db/
kubectl -n <ns> scale statefulset <name> --replicas=1
```

### Restore into a PVC

```bash
kubectl -n <ns> scale statefulset <name> --replicas=0
rsync -avz --delete main6:/backup/cardano/mainnet/db/ <db-hostpath>/
kubectl -n <ns> scale statefulset <name> --replicas=1
```

> ⚠️ For a BP, scaling to 0 stops block production. Do it in a low-risk window and
> only when relays are healthy. Prefer restoring on a **relay** or a spare node,
> then promoting.

### Verify a restore

```bash
kubectl -n <ns> rollout status statefulset <name>
scripts/health/check-sync.sh <node>     # confirm it resumes from the backup tip
```

## Retention Policy

| Data | Retention | Notes |
|------|-----------|-------|
| Pool keys | Forever | Multiple copies on offline storage |
| DB backups | 7 days | Rotate via `find -mtime +7 -delete` |
| Guild DB | 30 days | Optional — can be rebuilt |
| Mithril data | 7 days | Can be re-downloaded |
