# Midnight Helm Chart

Deploys a **Midnight validator** plus its **Cardano companion stack**
(cardano-node, cardano-db-sync, Ogmios, PostgreSQL) as a single release. This is
the Helm packaging of the manifests in
[chains/midnight/k3s](../../chains/midnight/k3s), matching the
[hybrid-node](../hybrid-node) chart conventions.

- Chart version: see [Chart.yaml](Chart.yaml) (`version`)
- App version: Midnight `1.0.0` (GA line)
- Default network: **Preview**

---

## Components

| Component        | Deployment      | Toggle                       | Default image                              |
|------------------|-----------------|------------------------------|--------------------------------------------|
| Midnight node    | `midnight-node` | always on                    | `midnightntwrk/midnight-node:1.0.0`        |
| Key inserter     | sidecar         | `midnightNode.keyInserter.enabled` | `curlimages/curl:latest`             |
| Cardano node     | `cardano-node`  | always on                    | `ghcr.io/intersectmbo/cardano-node:11.0.1` |
| Cardano db-sync  | `cardano-db-sync` | `dbSync.enabled`           | `ghcr.io/intersectmbo/cardano-db-sync:13.7.0.5` |
| Ogmios           | `ogmios`        | `ogmios.enabled`             | `cardanosolutions/ogmios:v6.14.0`          |
| PostgreSQL       | `postgres`      | `postgres.enabled`           | `postgres:15.3`                            |

Service names are kept **literal** (`postgres`, `cardano-node`, `midnight-rpc`,
`midnight-p2p`, `midnight-metrics`) so in-stack DNS and the shared IPC socket
(`ipcHostPath`) keep working.

---

## Quick start

```bash
# 1. Copy an example and fill in the CHANGE-ME values (never commit real keys)
cp charts/midnight/values-preview-example.yaml my-values.yaml
$EDITOR my-values.yaml

# 2. Install (creates the namespace if missing)
helm install midnight ./charts/midnight -n midnight --create-namespace \
  -f my-values.yaml

# 3. Watch it come up
kubectl -n midnight get pods -w
```

> ⚠️ The Midnight RPC opens on `:9944` ~30–60s **after** the pod starts (it builds
> DB indexes and the txpool first). Don't check readiness immediately.

### Example values files

| File | Use when |
|------|----------|
| [values-preview-example.yaml](values-preview-example.yaml) | Typical install — chart renders secrets, fresh PVCs on k3s `local-path`. |
| [values-external-example.yaml](values-external-example.yaml) | You manage secrets yourself (Vault/sealed-secrets) and/or re-attach existing PVCs. |

---

## Configuration

Full defaults are documented inline in [values.yaml](values.yaml). Highlights:

| Key | Default | Description |
|-----|---------|-------------|
| `network` | `preview` | Network preset for cardano-node / db-sync / midnight-node. |
| `imagePullSecrets` | `[]` | Pull secrets for private registries. |
| `ipcHostPath` | `/tmp/midnight-cardano-ipc` | Shared hostPath for the cardano-node ↔ db-sync/ogmios IPC socket. |
| `secrets.create` | `true` | Render `postgres-secret` + `midnight-secrets` from values, or BYO. |
| `postgres.persistence.size` | `50Gi` | Postgres PVC size. |
| `cardanoNode.persistence.size` | `150Gi` | Cardano node DB PVC size. |
| `dbSync.enabled` / `.persistence.size` | `true` / `100Gi` | db-sync toggle + PVC. |
| `ogmios.enabled` | `true` | Ogmios WebSocket bridge toggle. |
| `midnightNode.persistence.size` | `100Gi` | Midnight data PVC size. |
| `midnightNode.keyInserter.enabled` | `true` | Sidecar that injects AURA/GRANDPA/SIDECHAIN keys via RPC. |
| `midnightNode.service.p2p` | `NodePort:30333` | P2P service type/port. |

Each component has its own `resources.requests/limits` and
`persistence.{enabled,size,storageClass,accessMode,existingClaim}` block.

---

## Secrets

When `secrets.create: true`, the chart renders two Opaque secrets from values:

| Secret | Keys |
|--------|------|
| `postgres-secret` | `password` |
| `midnight-secrets` | `node-key`, `sidechain-pub-key`, `aura-pub-key`, `grandpa-pub-key`, `bootnodes` |

To manage them yourself, set `secrets.create: false` and pre-create secrets with
**exactly those names and keys** (see
[values-external-example.yaml](values-external-example.yaml)).

Generate a libp2p node key:

```bash
docker run --rm parity/subkey:latest generate-node-key
```

> Never commit real keys. The example files use `CHANGE-ME` placeholders on
> purpose.

---

## Upgrade / uninstall

```bash
# Upgrade in place
helm upgrade midnight ./charts/midnight -n midnight -f my-values.yaml

# Uninstall (PVCs are retained by default — delete them manually if desired)
helm uninstall midnight -n midnight
kubectl -n midnight get pvc   # review, then `kubectl delete pvc ...` if wiping
```

Midnight uses the `Recreate` strategy where PVCs are `ReadWriteOnce` (a
RollingUpdate would deadlock on the volume). Chain-data resets require deleting
the on-disk DB; see [chains/midnight/README.md](../../chains/midnight/README.md).

---

## Validate before install

```bash
helm lint charts/midnight
helm template midnight charts/midnight -f my-values.yaml | less
```

---

## Related

- [chains/midnight/README.md](../../chains/midnight/README.md) — chain module, network details, ops notes
- [hybrid-node chart](../hybrid-node) — Cardano/ApexFusion/Leios node chart
- [docs/deployment.md](../../docs/deployment.md) — platform deployment guide
