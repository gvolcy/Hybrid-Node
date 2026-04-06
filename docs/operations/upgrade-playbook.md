# Upgrade Playbook

## Pre-Upgrade Checklist

- [ ] Verify the new version is tested on preview/preprod before mainnet
- [ ] Check [cardano-node releases](https://github.com/IntersectMBO/cardano-node/releases) for breaking changes
- [ ] For ApexFusion: confirm compatibility with [prime-docker](https://github.com/APN-Fusion/prime-docker) before bumping
- [ ] Backup current DB: `scripts/health/check-disk.sh` to ensure space
- [ ] Have rollback image tag ready

## Upgrade Procedure

### 1. Update version pins

```bash
# Edit the appropriate versions.env
vi chains/cardano/versions.env    # or chains/apexfusion/versions.env
```

### 2. Build new image

```bash
make build CHAIN=cardano
# or
make build CHAIN=apexfusion
```

### 3. Test on non-production first

```bash
# Deploy to preview/preprod
docker run -d --name test-upgrade \
  -e NETWORK=preprod \
  -e NODE_MODE=relay \
  -v test-db:/opt/cardano/cnode/db \
  ghcr.io/gvolcy/hybrid-node:cardano-<new-version>

# Wait for sync and verify
scripts/health/check-sync.sh test-upgrade
```

### 4. Rolling upgrade — relays first

```bash
# Upgrade main3 relay
ssh main3 'docker pull ghcr.io/gvolcy/hybrid-node:cardano-<new-version>'
ssh main3 'docker stop cardano-relay && docker rm cardano-relay'
ssh main3 'docker run -d --name cardano-relay ... ghcr.io/gvolcy/hybrid-node:cardano-<new-version>'

# Verify sync
ssh main3 'scripts/health/check-sync.sh cardano-relay'

# Repeat for main4, main5
```

### 5. Upgrade BP (last)

```bash
# Only after ALL relays are upgraded and synced
ssh main1 'docker pull ghcr.io/gvolcy/hybrid-node:cardano-<new-version>'
ssh main1 'docker stop cardano-bp && docker rm cardano-bp'
ssh main1 'docker run -d --name cardano-bp ... ghcr.io/gvolcy/hybrid-node:cardano-<new-version>'
```

### 6. Post-upgrade verification

```bash
scripts/health/check-all.sh cardano-bp
scripts/health/check-all.sh cardano-relay
```

## Helm Upgrade

```bash
helm upgrade cardano-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-relay-example.yaml \
  --set image.tag=cardano-<new-version>
```

## Important Notes

- **Always upgrade relays before BPs** — BPs need relays to be on the same or newer version
- **Never upgrade all relays simultaneously** — maintain at least one running relay at all times
- **DB format changes** — some node upgrades require a full re-sync (check release notes)
- **Mithril** — after a DB re-sync, Mithril client can bootstrap the chain much faster
