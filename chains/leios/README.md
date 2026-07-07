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
- Configs: [Cardano Operations Book — Musashi](https://book.play.dev.cardano.org/adv-musashi.html) (`environments-pre/leios`, magic 164)

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

There are two image options for a Leios relay:

| Option | Image | Build | Includes | Use when |
|--------|-------|-------|----------|----------|
| **A — Prebuilt (IOG)** | `ghcr.io/input-output-hk/ouroboros-leios/cardano-node-testnet:latest` | none (pull) | node + cli + pinned configs | You just want a synced relay fast |
| **B — Hybrid-Node** | `ghcr.io/gvolcy/hybrid-node:leios-11.1.0` ✅ built & pushed | `make build-leios` (~1–2h source compile) | + Guild tooling, healthcheck, entrypoint | You want full platform consistency |

> The **`leiosT1` / `leiosT2` / `leiosT3`** relays and **`leios-volcy` / `leios-silem`** BPs run
> **Option B** — `ghcr.io/gvolcy/hybrid-node:leios-11.1.0` with the shared entrypoint.
> Fleet nodes pin git `3cc6340a` (prototype-2026w27) for chain-db compatibility with the IOG prebuilt binary.
> One-shot CLI pods can use a HEAD build (`7c357a55`) for Dijkstra cert/tx work.

### Option A — Prebuilt IOG relay (deployed as `leiosT1`)

```bash
# Docker
docker run -d --name leios-relay \
  -e PORT=3010 -e CARDANO_NODE_NETWORK_ID=164 \
  -v leios-data:/data \
  -p 3010:3010 \
  ghcr.io/input-output-hk/ouroboros-leios/cardano-node-testnet:latest

# K3s (leiosT1)
kubectl apply -f chains/leios/k3s/leiost1.yaml
```

### Option B — Hybrid-Node relay (requires `make build-leios`)

```bash
# Docker
docker run -d \
  --name musashi-relay \
  -e NETWORK=leios \
  -e NODE_MODE=relay \
  -e NODE_PORT=3001 \
  -v leios-db:/opt/cardano/cnode/db \
  -p 3001:3001 \
  -p 12798:12798 \
  ghcr.io/gvolcy/hybrid-node:leios-11.1.0

# K3s
kubectl apply -f chains/leios/k3s/relay.yaml

# Helm
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
    ├── leiost1.yaml         # leiosT1 relay (Option B — main3)
    ├── leiost2.yaml         # leiosT2 relay (Option B — Hybrid-Node, main4)
    ├── leiost3.yaml         # leiosT3 relay (Option B — Hybrid-Node, main5)
    ├── relay.yaml           # Generic relay (Option B — Hybrid-Node image)
    └── main2/
        ├── leios-volcy.yaml # VOLCY block producer (main2)
        └── leios-silem.yaml # SILEM block producer (main2)
```

### Fleet

| Node | Role | Host | Port | Tailscale | Status |
|------|------|------|------|-----------|--------|
| `leiosT1` | relay | main3 | 3010 | `100.103.135.9` | deployed |
| `leiosT2` | relay | main4 | 3010 | `100.110.37.42` | deployed |
| `leiosT3` | relay | main5 | 3010 | `100.125.176.60` | deployed |
| `leios-volcy` | block producer | main2 | 6000 | — | deployed (forging) |
| `leios-silem` | block producer | main2 | 6001 | — | deployed (forging) |

The two BPs peer with all three relays (leiosT1/T2/T3 over Tailscale, as
`localRoots`) **and** with the public Leios bootstrap relay
(`leios-node.play.dev.cardano.org:3001`) plus ledger peers. The public bootstrap
is **required**: a Leios BP that peers only with private relays never receives
endorser-block (EB) bodies and crashes at apply-time with Issue #890.

**On-chain:** both pools registered (5k pledge, 3% margin, 170 ADA cost) with three
relays in the pool cert. Faucet delegation still pending.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `leios` | Selects Musashi Dojo configs + magic 164 |
| `NODE_MODE` | `relay` | `relay` or `bp` |
| `NODE_PORT` | `3001` | Node listening port |
| `MITHRIL_DOWNLOAD` | `N` | Must be `N` — Mithril unavailable for Leios |
| `CUSTOM_PEERS` | — | Extra relay peers `addr:port,...` (BP `localRoots`) |
| `BOOTSTRAP_PEERS` | — | Trusted bootstrap peers `addr:port,...`. **Required for a Leios BP** (EB delivery) or it crashes with #890 |
| `USE_LEDGER_AFTER_SLOT` | `-1` | Use ledger peers after this slot (`1000` for Leios BPs; `-1` disables) |

---

## Block Producers (forging)

Two BPs (`leios-volcy`, `leios-silem`) are deployed on main2 via
[`k3s/main2/`](k3s/main2/). They run the prototype `cardano-node` with the
standard **KES + VRF + op.cert** credentials and an **EB-connected topology**
(public bootstrap + leiosT1/T2/T3 + ledger peers), so they sync, survive replay,
and **forge**.

### Issue #890 — no-restart policy (critical)

The Musashi prototype can crash on **cold start** with:

`Issue #890 gate missed … cert: LeiosCert`

This is a **ledger replay** bug in the prototype consensus layer. Historically this was
**not** fixed by rebuilding the image; **prototype-2026w27** (git pin `3cc6340a`) is the
first build to address the #890 class directly (relative `LeiosDbConfig` path + staging-area
replacement), so keep the fleet on that pin.

**Root cause.** On this testnet a fresh sync eventually reaches a region where the
public network no longer serves the historical **endorser-block (EB) bodies**. The
node applies blocks forward fine (EBs available live) but does **not** persist EB
bodies, so its newest ledger snapshot ends up **behind** a slot whose EB is gone.
On the next restart, ledger **replay** re-applies that slot, cannot re-fetch the EB
(replay is local-only), and aborts with #890. The db is then permanently poisoned.
Only a **continuously-online** node (a relay) holds recent snapshots past the poison.

**Two things are needed for a healthy BP:**
1. An **EB-connected topology** (`BOOTSTRAP_PEERS` = public bootstrap, `CUSTOM_PEERS`
   = relays, `USE_LEDGER_AFTER_SLOT=1000`) so it receives EB bodies while live.
2. A **non-poisoned db** — seed it from the healthy relay, never a cold fresh sync
   past the EB wall.

**Operational rules**

| Do | Don't |
|----|-------|
| **Seed the db from the healthy relay** (recent snapshot past the poison) | Cold-sync a BP from genesis past the EB wall (→ poisoned db) |
| Give the BP an **EB-connected topology** (bootstrap + relays + ledger peers) | Peer a BP with private relays only (→ EB-starved → #890) |
| Keep BPs **online**; snapshot often | Restart a BP whose newest snapshot is behind an un-refetchable EB |
| Restore keys at 100% via **SIGHUP** (no pod restart) | Recycle the pod to “enable” forging |
| Leave **leiosT1 / leiosT3** running (they are the golden-db source) | Restart every relay at once (you lose the seed source) |

**Manifest hardening** (in `k3s/main2/*.yaml`):

- `START_AS_NON_PRODUCING=true` — dynamic forging toggle via SIGHUP
- **No livenessProbe** — mid-sync healthcheck restarts caused crash loops
- Generous `startupProbe` + relaxed `readinessProbe` (readiness does not kill pods)

**Helper scripts:**

```bash
# Fleet sync / restart summary (run on main2; set KUBECTL='sudo k3s kubectl')
chains/leios/bin/leios-fleet-status

# RECOVER a poisoned / #890-looping BP: seed its db from the healthy relay.
# Run from the operator workstation (orchestrates relay + BP hosts over SSH).
chains/leios/bin/leios-bp-seed-from-relay leios-volcy
chains/leios/bin/leios-bp-seed-from-relay leios-silem

# After 100% with 0 restarts — restore keys + SIGHUP (no pod restart)
ssh main2 'KUBECTL="sudo k3s kubectl" /home/mvolcy2/bin/leios-bp-enable-forging leios-volcy'
ssh main2 'KUBECTL="sudo k3s kubectl" /home/mvolcy2/bin/leios-bp-enable-forging leios-silem'
```

> `leios-bp-sync-start` (cold resync from leiosT1 only) is **superseded** for BPs:
> a cold sync gets poisoned at the EB wall. Use `leios-bp-seed-from-relay` instead.

**Manual recovery** (what `leios-bp-seed-from-relay` automates): scale the BP to 0;
move `data/db` aside; create a fresh empty `db/`; copy `immutable/`, `ledger/` and
the `protocolMagicId` marker from the healthy relay's db (**skip** `volatile/`);
write an EB-connected `data/files/topology.json` (bootstrap + relays +
`useLedgerAfterSlot:1000`); set `NODE_MODE=bp START_AS_NON_PRODUCING=true` with the
topology pinned via `TOPOLOGY`; keep operational keys (no `cold.*`) in `priv/`;
scale to 1. The node loads the recent snapshot and fetches the last blocks live —
no poisoned replay.

> **Do not `kubectl apply` updated BP manifests while a node is stable** unless the
> image already honours `BOOTSTRAP_PEERS`/`USE_LEDGER_AFTER_SLOT` (rebuild, or apply
> `platform/docker/Dockerfile.entrypoint-overlay`). On the old entrypoint, setting
> `CUSTOM_PEERS` rebuilds the topology with empty `bootstrapPeers` (EB-starved).

**Forging is enabled** with the standard **KES + VRF + op.cert** credentials
(injected at 100% sync via `leios-bp-enable-forging`, SIGHUP, no restart). BLS is
**not yet required** by the current release — upstream has announced that a future
node version will require pools to additionally register a **BLS key**:

| Capability | `cardano-cli` (`dijkstra node ...`) | Status |
|------------|-------------------------------------|--------|
| Forge with KES + VRF + op.cert | `cardano-node run --shelley-kes-key ...` | ✅ live |
| Generate BLS key / hash / PoP | `key-gen-BLS`, `key-hash-BLS`, `issue-pop-BLS` | ✅ available |
| Register BLS in pool cert | `stake-pool registration-certificate --bls-*` | ⏳ upcoming |
| Forge with BLS | `cardano-node run --shelley-bls-key` | ⏳ upcoming |

Each pool's full key set — including `bls.{vkey,skey,hash,pop}` — is already
generated and stored on main2 at `/data/leios/<pool>/priv`, ready for when upstream
ships the BLS registration cert fields and startup flag. Track
[ouroboros-leios#776](https://github.com/input-output-hk/ouroboros-leios/issues/776)
and [cardano-cli#1355](https://github.com/IntersectMBO/cardano-cli/pull/1355).

> ⚠️ Keys live only on the host (`/data/leios/<pool>/priv`) and are **not** committed.

---

## Upstream Resources

| Resource | Link |
|----------|------|
| Musashi Dojo | [musashi.network](https://www.musashi.network/) |
| Leios overview | [leios.cardano-scaling.org](https://leios.cardano-scaling.org/) |
| Leios repo | [input-output-hk/ouroboros-leios](https://github.com/input-output-hk/ouroboros-leios) |
| CIP-0164 | [Ouroboros Linear Leios](https://github.com/cardano-foundation/CIPs/pull/1078) |
| Configs | [Cardano Operations Book (Musashi)](https://book.play.dev.cardano.org/adv-musashi.html) |
