# Leios / Musashi Dojo Chain Module

This directory contains Ouroboros Leios (Musashi Dojo testnet) configuration and deployment manifests for the [Hybrid-Node](../../README.md) platform.

[Musashi Dojo](https://www.musashi.network/) is the public Cardano testnet for **Ouroboros Leios**, Cardano's next-generation high-throughput consensus protocol (CIP-0164). It uses the same `cardano-node` lineage as Cardano but runs a **prototype build** with a new Dijkstra ledger era and a Leios block-diffusion layer.

> Status: prototype / experimental. The Leios node is not an upstream release; the build ref must be confirmed before building the image.

---

## Supported Network

| Network | Description | Magic | Port | Status |
|---------|-------------|-------|------|--------|
| `leios` | Ouroboros Leios — Musashi Dojo testnet | 164 | 3001 | Prototype |

- Bootstrap peer: `leios-node.play.dev.cardano.org:3001`
- CLI flag: `--testnet-magic 164` (`CARDANO_NODE_NETWORK_ID=164`)
- Configs: [cardano-playground `next-2026-05-15`](https://github.com/input-output-hk/cardano-playground/tree/next-2026-05-15/docs/environments-pre/leios)

---

## Architecture

Leios reuses the shared Hybrid-Node platform (same entrypoint, Helm chart, and
K3s patterns as Cardano/ApexFusion). Chain separation happens at the **binary +
genesis + consensus layer**, not the platform layer.

```
┌──────────────────────────────────────────────────────────┐
│         cardano-node (leios-prototype branch)            │
│                                                          │
│   ┌────────────────────────────────────────────────┐    │
│   │   Ouroboros Leios  (over Ouroboros Praos)        │   │
│   │   • Praos ranking blocks (RB) = base security    │   │
│   │   • Endorser blocks (EB) = extra throughput      │   │
│   │   • Committee validation before ledger inclusion │   │
│   └────────────────────────────────────────────────┘    │
│                                                          │
│   ┌──────────────────────┐  ┌────────────────────────┐  │
│   │ 5 genesis eras        │  │ Leios SQLite store     │  │
│   │ byron→…→conway+       │  │ leios.db (EB tx data)  │  │
│   │ DIJKSTRA              │  │ LeiosDbConfig          │  │
│   └──────────────────────┘  └────────────────────────┘  │
│                                                          │
│   Guild Operators tooling · CNCLI · nview · txtop        │
│   Mithril: NOT available (sync from bootstrap peer)      │
└──────────────────────────────────────────────────────────┘
        │ NETWORK=leios (magic 164)
        ▼
  leios-node.play.dev.cardano.org:3001  (Musashi Dojo bootstrap)
```

Full platform-wide architecture (host topology, build pipeline, port map) lives in
[docs/architecture.md](../../docs/architecture.md#leios--musashi-dojo-stack).

---

## Key Differences from Cardano

| Feature | Cardano | Leios (Musashi) |
|---------|---------|-----------------|
| Node binary | Release tag (e.g. 11.0.1) | **Prototype** `11.0.1-leios-prototype` |
| Genesis eras | 4 (byron/shelley/alonzo/conway) | **5** (adds `dijkstra-genesis.json`) |
| Leios store | — | `LeiosDbConfig` SQLite `leios.db` |
| Mithril | Available | Not available (sync from bootstrap peer) |
| Block producer | KES + VRF + op.cert | Additionally requires **BLS keys** (pending) |

---

## Build Source (IMPORTANT)

The Leios node is built from the **`leios-prototype` branch** of `cardano-node`
(not a release tag). That branch's `cabal.project` pins the patched
`ouroboros-consensus` / `ouroboros-network` commits, so a plain build resolves
them. The node self-reports version `11.0.1-leios-prototype`.

```bash
# Default build (branch leios-prototype):
make build-leios

# Override the ref/repo if upstream moves the prototype branch:
make build-leios \
  NODE_REPO=https://github.com/IntersectMBO/cardano-node.git \
  NODE_BUILD_REF=leios-prototype
```

See [platform/docker/Dockerfile.leios](../../platform/docker/Dockerfile.leios) (`NODE_REPO` / `NODE_BUILD_REF` build args). Track prototype progress in [ouroboros-leios](https://github.com/input-output-hk/ouroboros-leios).

---

## Quick Start

### Docker — Relay

```bash
docker run -d \
  --name musashi-relay \
  -e NETWORK=leios \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v leios-db:/opt/cardano/cnode/db \
  -p 3001:3001 \
  -p 12798:12798 \
  ghcr.io/gvolcy/hybrid-node:leios-11.0.1
```

### Kubernetes (K3s)

```bash
kubectl apply -f chains/leios/k3s/relay.yaml
```

### Helm

```bash
helm install musashi-relay ./charts/hybrid-node \
  -f charts/hybrid-node/values-leios-relay.yaml
```

---

## Structure

```
leios/
├── README.md
├── versions.env             # Node/config/tool pins + network params
├── configs/
│   └── leios/               # Optional config overrides (dir name == NETWORK)
└── k3s/
    └── relay.yaml           # Musashi Dojo relay deployment
```

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `leios` | Selects Musashi Dojo configs + magic 164 |
| `NODE_MODE` | `relay` | `relay` or `bp` |
| `NODE_PORT` | `3001` | Node listening port |
| `MITHRIL_DOWNLOAD` | `N` | Must be `N` — Mithril unavailable for Leios |
| `CUSTOM_PEERS` | — | Extra peers `addr:port,...` (BP relay lock-down) |

---

## Block Producer (Not Yet Supported)

BP mode needs **BLS keys** in addition to the standard KES/VRF/op.cert set, and
the registration certificate fields (`--bls-verification-key-file`, `--bls-pop-file`)
plus the node flag `--shelley-bls-key` are still pending in `cardano-cli` and the
ledger. Track [ouroboros-leios#776](https://github.com/input-output-hk/ouroboros-leios/issues/776).
A `values-leios-bp.yaml` and `k3s/bp.yaml` will be added once BLS support lands.

---

## Upstream Resources

| Resource | Link |
|----------|------|
| Musashi Dojo | [musashi.network](https://www.musashi.network/) |
| Leios overview | [leios.cardano-scaling.org](https://leios.cardano-scaling.org/) |
| Leios repo | [input-output-hk/ouroboros-leios](https://github.com/input-output-hk/ouroboros-leios) |
| CIP-0164 | [Ouroboros Linear Leios](https://github.com/cardano-foundation/CIPs/pull/1078) |
| Configs | [cardano-playground (leios)](https://github.com/input-output-hk/cardano-playground/tree/next-2026-05-15/docs/environments-pre/leios) |
