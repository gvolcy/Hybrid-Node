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

## Retention Policy

| Data | Retention | Notes |
|------|-----------|-------|
| Pool keys | Forever | Multiple copies on offline storage |
| DB backups | 7 days | Rotate via `find -mtime +7 -delete` |
| Guild DB | 30 days | Optional — can be rebuilt |
| Mithril data | 7 days | Can be re-downloaded |
