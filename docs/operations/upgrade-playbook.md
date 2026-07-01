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

### K3s / StatefulSet rolling upgrade

The chart uses `strategy.type: Recreate` (two nodes can't share one DB), so each
pod stops before its replacement starts. Upgrade **one release at a time**,
relays before BPs, verifying sync between each.

```bash
# 1. Bump the image tag on a relay release (triggers a Recreate rollout)
helm upgrade <relay-release> ./charts/hybrid-node \
  -f <relay-values> --set image.tag=cardano-<new-version>

# 2. Watch the rollout and wait for the new pod to become Ready + synced
kubectl -n <ns> rollout status statefulset <relay-name>
scripts/health/check-sync.sh <relay-node>

# 3. Repeat for each remaining relay, one at a time (keep >=1 relay up always)

# 4. Only after ALL relays are upgraded and synced, upgrade the BP release
helm upgrade <bp-release> ./charts/hybrid-node \
  -f <bp-values> --set image.tag=cardano-<new-version>
kubectl -n <ns> rollout status statefulset <bp-name>
scripts/health/check-all.sh <bp-node>
```

> Pin `image.tag` in your values file (not `latest`) so the running version is
> explicit and rollback targets are unambiguous.

## Important Notes

- **Always upgrade relays before BPs** — BPs need relays to be on the same or newer version
- **Never upgrade all relays simultaneously** — maintain at least one running relay at all times
- **DB format changes** — some node upgrades require a full re-sync (check release notes)
- **Mithril** — after a DB re-sync, Mithril client can bootstrap the chain much faster
