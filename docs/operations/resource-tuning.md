# Resource Requirements & Tuning

Guidance for sizing and tuning nodes by **role** (relay vs block producer) and
**network** (mainnet vs testnet). Values are general Cardano guidance for
cardano-node 10.x — adjust to your observed usage (`kubectl top pod`, `docker stats`).

## Quick Reference

| Role | Network | CPU (req/lim) | Memory (req/lim) | DB disk | Notes |
|------|---------|---------------|------------------|---------|-------|
| Relay | mainnet | 2 / 4 cores | 16Gi / 24Gi | 150–200Gi | Public-facing; scales with peer count |
| Block Producer | mainnet | 4 / 4 cores | 16Gi / 24Gi | 150–200Gi | + CNCLI/leaderlog overhead; needs low GC pause |
| Relay | preprod/preview | 2 / 2 cores | 6Gi / 10Gi | 40–80Gi | Much smaller chain |
| Block Producer | preprod/preview | 2 / 2 cores | 8Gi / 12Gi | 40–80Gi | + CNCLI overhead |
| ApexFusion relay | afpm | 2 / 4 cores | 8Gi / 16Gi | 40–60Gi | Smaller chain than Cardano mainnet |
| ApexFusion BP | afpm | 2 / 4 cores | 8Gi / 16Gi | 40–60Gi | No Mithril; plan for full re-sync |

> Memory grows over time as the ledger state and UTxO set grow. Set **limits**
> with headroom (a mainnet node's resident set is ~14–18 GB and climbing). If the
> container is OOM-killed mid-write it can corrupt the DB and force a re-sync.

## Relay vs Block Producer — what differs

- **Relays** are I/O- and network-bound. They handle inbound/outbound peer
  connections (P2P) and chain propagation. More peers = more memory and CPU.
- **Block Producers** carry the same base node load **plus**:
  - CNCLI (`sync`, `leaderlog`, `validate`) — extra CPU/disk on the guild DB.
  - Mithril signer (optional) — small, periodic.
  - **Latency sensitivity**: a BP must evaluate slot-leader checks on time. Long
    GC pauses can cause a missed block. Prefer GC tuning that lowers pause time
    (see below) over raw throughput.

## CPU / RTS tuning

The image sets the GHC RTS `-N` flag from `CPU_CORES` (chart: `cardano.cpuCores`).
Extra RTS options go in `RTS_OPTS` (chart: `cardano.rtsOpts`).

```yaml
cardano:
  cpuCores: 4          # -> RTS -N4 (match to allocated CPU limit)
  rtsOpts: "-A16m -qg -qb0 -I0 --disable-delayed-os-memory-return"
```

Common flags:

| Flag | Effect | When |
|------|--------|------|
| `-N<n>` | Use `<n>` capabilities (set via `CPU_CORES`) | Match to CPU limit |
| `-A16m` | Larger allocation area → fewer minor GCs | General |
| `-I0` | Disable idle GC | Reduce idle-time pauses |
| `--nonmoving-gc` | Concurrent GC → shorter pauses | **BPs**, to avoid missed slots |
| `--disable-delayed-os-memory-return` | Return freed memory to OS immediately | Memory-constrained hosts |
| `-qg -qb0` | Tune parallel GC | Multi-core |

> **BP recommendation:** consider `--nonmoving-gc` to minimize pause time. Test on
> preprod first — the non-moving collector trades a little throughput for much
> lower max pause, which is what a BP cares about.

Set `cpuCores` equal to (or one below) your CPU **limit**. Over-subscribing `-N`
above the CPU limit causes scheduler contention and higher GC pauses.

## Memory sizing

- Set **requests** to steady-state resident memory so the scheduler places the pod
  correctly; set **limits** with ~40–50% headroom for growth and GC spikes.
- Do **not** run without a memory limit on shared hosts — a leak or GC spike can
  evict neighbours. But set the limit high enough to avoid OOM-kills during DB
  writes (which corrupt the DB).
- On K3s single-node hosts, watch total committed memory across all pods vs host RAM.

## Disk & I/O

- Blockchain DB is the hot path — use **SSD/NVMe**. Spinning disks cannot keep up
  with mainnet.
- Size DB volumes with headroom (chain grows continuously). See the table above.
- Guild DB (CNCLI) adds ~5–10Gi on BPs.
- Provision an IOPS-capable storage class; slow disks cause sync lag and, on BPs,
  missed blocks.

## Applying in Helm

Relay ([values-relay-example.yaml](../../charts/hybrid-node/values-relay-example.yaml)):

```yaml
cardano:
  cpuCores: 4
resources:
  requests: { memory: "16Gi", cpu: "2" }
  limits:   { memory: "24Gi", cpu: "4" }
persistence:
  db: { enabled: true, size: 200Gi }
```

Block producer ([values-bp-example.yaml](../../charts/hybrid-node/values-bp-example.yaml)):

```yaml
cardano:
  cpuCores: 4
  cncliEnabled: "Y"
  rtsOpts: "-A16m --nonmoving-gc --disable-delayed-os-memory-return"
resources:
  requests: { memory: "16Gi", cpu: "4" }
  limits:   { memory: "24Gi", cpu: "4" }
persistence:
  db:      { enabled: true, size: 200Gi }
  guildDb: { enabled: true, size: 10Gi }
```

Apply a change (triggers a `Recreate` rollout — one node at a time):

```bash
helm upgrade <release> ./charts/hybrid-node -f <values-file> --reuse-values
```

## Verifying after a change

```bash
# Live usage
kubectl -n <ns> top pod
docker stats --no-stream <container>

# Confirm the node is keeping up (no growing slot gap)
scripts/health/check-sync.sh <node>
scripts/health/check-memory.sh <node>
```

> ⚠️ Changing resources restarts the node. On BPs, do it during a low-risk window
> and only when relays are healthy.
