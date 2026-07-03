# Leios prototype: EB-closure store (`leios.db`) is non-persistent and immutable-DB replay aborts (`#890 gate missed`) on restart

> Draft issue for **input-output-hk/ouroboros-leios** (or IntersectMBO/ouroboros-consensus).
> Relates to the *open points* of the closed issue #890 ("Prototype: CertRB staging area and catch-up").

## Summary

On the Musashi Dojo Leios testnet (network magic `164`), a `cardano-node`
`leios-prototype` block producer / relay **cannot recover from a restart using its
own on-disk database**. After any container/process restart, ledger replay of the
immutable DB aborts with:

```
cardano-node: Issue #890 gate missed: apply-time resolve found EB
EbAnnouncement {ebAnnouncementHash = <hash>, ebAnnouncementSize = <n>}
at last-slot At (SlotNo <N>) absent; cert: LeiosCert
  error, called at ouroboros-consensus-cardano/src/shelley/Ouroboros/Consensus/Shelley/Ledger/Ledger.hs:1038
```

There appear to be **two contributing defects**:

1. **`LeiosDbConfig.Filepath` defaults to a relative path**, so the endorser-block
   (EB) closure store `leios.db` is written **outside** `--database-path` and is
   silently lost on restart / redeploy / from db backups.
2. **The immutable-DB replay path (`InitChainSel`) does not go through the CertRB
   staging area / fetch mechanism** introduced in #890 / consensus #2058. When the
   EB closure is missing from `leios.db`, replay aborts instead of staging + fetching.

Individually each is recoverable-ish; **together** they make a node unrecoverable
from its local db and force an out-of-band copy of another node's data directory.

## Environment

- Node: `cardano-node` `leios-prototype` branch, reported version `11.0.1-leios-prototype`
  (build ref `40888f50725e473d91f40e554e2d436dfc80a924`, ~2026-06-24; i.e. after the
  prototype-2026w24/w25 staging-area and block-fetch fixes).
- Network: Musashi Dojo public Leios testnet, `NETWORK_MAGIC=164`, Dijkstra era (PV12).
- Deployment: containerised, working directory `/opt/cardano/cnode`,
  `--database-path /opt/cardano/cnode/db` (a persistent volume mount).

## Defect 1 — EB-closure store is written outside `--database-path`

The shipped `config.json` (from the Cardano Operations Book Leios environment) contains:

```json
"LeiosDbConfig": {
  "Filepath": "leios.db"
}
```

`Filepath` is **relative**, and the node resolves it against its working directory
(`/opt/cardano/cnode`), **not** against `--database-path`. Observed on a running node:

```
# cwd of the node process
/proc/<pid>/cwd -> /opt/cardano/cnode

# EB-closure store (4.1 GB) sits at the cnode root, NOT under the db mount:
-rw-r--r-- 1 ... 4115316736  /opt/cardano/cnode/leios.db
-rw-r--r-- 1 ...   24089672  /opt/cardano/cnode/leios.db-wal
-rw-r--r-- 1 ...      65536  /opt/cardano/cnode/leios.db-shm

# the only persistent mounts are the db path and siblings:
/opt/cardano/cnode/db      (persistent volume)
/opt/cardano/cnode/files
/opt/cardano/cnode/sockets
...
# /opt/cardano/cnode/leios.db is on the container's ephemeral rootfs
```

Consequences:
- On container recreation the entire EB-closure store is wiped.
- `leios.db` is **not** co-located with the chain db, so ordinary db backups and
  "copy the data directory" recovery procedures miss it.
- Interestingly, an earlier build (~2026-06-24 snapshot) wrote `leios.db` *inside*
  the `db/` directory; the current build writes it at the cnode root — so the
  location silently changed and existing volume layouts no longer capture it.

**Suggested fix:** default `LeiosDbConfig.Filepath` to a path under `--database-path`
(e.g. `<database-path>/leios.db`), or resolve a relative `Filepath` against
`--database-path` rather than CWD. At minimum, document that this file must live on
the same persistent volume as the chain db.

## Defect 2 — immutable-DB replay aborts instead of staging/fetching (open point #2 of #890)

Issue #890 added a CertRB staging area (consensus #2058) plus EB resolution on the
immutable-DB replay path (commit `fbaa872`). The staging gate is installed on
`addBlockAsync`, so it protects the **live** path. The issue's own "open points"
already note (point #2):

> *"InitChainSel bypasses the staging gate. … if the closure later goes missing
> (LeiosDb wipe, crash between ChainSel adopt and LeiosDb flush, file corruption),
> restart's InitChainSel hits the original error because the wrap sits on
> `addBlockAsync` and is skipped at startup."*

Because of Defect 1, "LeiosDb wipe" happens on **every** restart, so this open point
is not an edge case in practice — it is the normal outcome of restarting a node.

**Repro:**
1. Sync a node so its immutable DB contains CertRBs.
2. Restart the node such that `leios.db` is empty/missing (trivially: any container
   restart, given Defect 1).
3. Node aborts during replay with `Issue #890 gate missed … SlotNo <N> absent`.

**Expected:** replay stages the unresolved CertRB and fetches the missing EB closure
from peers (as the live path does), or the node continues and back-fills, rather than
crashing.

**Suggested fix:** route the startup/`InitChainSel` replay path through the same
staging + fetch mechanism as `addBlockAsync` (the long-run "make ChainSel aware of
missing-cert-closure state and resolve at adoption time" design noted in #890).

## Additional observation — reseeds are timing-fragile

Because peers never persist EB bodies and replay is local-only, recovering a node by
copying `immutable/ + ledger/` from a healthy node only succeeds if the copied ledger
snapshot and the copied immutable tip fall within the **same cert-free interval**. In
practice the first Leios certificate lands only ~35–40 slots above a fresh snapshot,
so any replay window wider than that re-triggers the abort. Persisting and copying
`leios.db` alongside the chain db (Defects 1 + 2) would remove this fragility.

## Workaround in use

- Pin `LeiosDbConfig.Filepath` to an absolute path inside the db volume so the store
  survives restarts.
- Include `leios.db` (+ `-wal`/`-shm`) when seeding a recovering node from a healthy
  one, so the EB closures travel with `immutable/ + ledger/`.
