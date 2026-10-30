# Dijkstra testnet (magic 6)

Hybrid-Node deployment notes for the public Dijkstra testnet. Configs and genesis come from the Cardano Operations Book pre-environment:

https://book.play.dev.cardano.org/environments-pre/dijkstra/

## Pin

See [`versions.env`](versions.env). Fleet image:

`ghcr.io/gvolcy/hybrid-node:cardano-11.2.0-dijkstra`

Built as a thin overlay of the official IntersectMBO `cardano-node` / `cardano-cli` 11.2.0 linux-amd64 tarball onto `cardano-11.1.3-dijkstra` (`platform/docker/Dockerfile.cardano-bin-overlay`).

**Do not** treat this as the mainnet Cardano pin — `chains/cardano` stays on 11.1.3 until IOG marks 11.2.0 mainnet-ready.

## Hard fork readiness

Book config is a cardano-config **envelope** (`Version` / `MinNodeVersion` / `Configuration`):

- `MinNodeVersion`: `11.2.0`
- `Configuration.Testing.ExperimentalHardForksEnabled`: `true`
- Genesis hashes unchanged from the prior flat config (same chain; upgrade + config swap, not a wipe)

`platform/bin/entrypoint.sh` with `NETWORK=dijkstra`:

- Downloads book config / topology / genesis / peer-snapshot
- Skips flat genesis-hash rewrites on envelopes
- Switches BP `Configuration.Consensus.ConsensusMode` GenesisMode → PraosMode
- Adds Guild-compatible top-level aliases (`ConwayGenesisFile`, `TraceOptions`, …) so gLiveView / `env` work against envelopes

## Ops

1. Relays first, then BPs. Do not restart BPs around leader slots.
2. Set `NETWORK=dijkstra`, `START_AS_NON_PRODUCING=true` on BPs.
3. After 100% sync, `kill -HUP` the **cardano-node** pid (not pid 1) to enable forging.
4. First boot on 11.2.0 may log `InvalidSnapshot` / ShelleyLedgerState size mismatch and replay ledger snapshots — expected; tip should catch up without a DB wipe.

## Hosts (VOLCY / SILEM)

| Role | Hosts | Port |
|------|-------|------|
| BPs (`dijkstra-bp`, `dijkstra-silem`) | main1 | 6000 / 6001 |
| Relays | main3 / main4 / main5 | 3011 |
