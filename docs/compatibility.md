# Compatibility Matrix

## Current Versions

| Component | Cardano | ApexFusion | Notes |
|-----------|---------|------------|-------|
| cardano-node | 11.0.1 | 10.1.4 | Source-built from IntersectMBO |
| cardano-cli | 11.0.0.0 | 9.4.1.0 | CLI version must match node era |
| GHC | 9.6.7 | 9.6.6 | Haskell compiler |
| Cabal | 3.12.1.0 | 3.12.1.0 | Build tool |
| Mithril client | 0.13.9 | — | Not available for ApexFusion |
| Mithril signer | 1.0.0 | — | Not available for ApexFusion |
| CNCLI | 6.7.0 | 6.7.0 | Leader logs, PoolTool |
| nview | 0.14.0 | 0.13.0 | TUI node monitor |
| txtop | 0.15.0 | 0.14.0 | Mempool viewer |
| Guild Operators | cardano-community/master | Scitz0/main | Different forks |
| Base image | debian:bookworm-slim | debian:bookworm-slim | Shared |
| Haskell image | 9.6.7-3.12.1.0-3 | 9.6.6-3.12.1.0-3 | Build stage only (blinklabs-io/haskell) |

## Midnight

| Component | Version | Notes |
|-----------|---------|-------|
| midnight-node | 1.0.0 | Pre-built from midnightntwrk |
| cardano-node (companion) | 11.0.1 | IntersectMBO official image (preview) |
| db-sync | 13.7.0.5 | IntersectMBO official image |
| ogmios | v6.14.0 | cardanosolutions official image |
| postgres | 15.3 | Database for db-sync |

## Infrastructure

| Component | Version | Notes |
|-----------|---------|-------|
| K3s | v1.28+ | Lightweight Kubernetes |
| Helm | v3.12+ | Chart deployment |
| Docker | 24.0+ | Container runtime |
| OS | Ubuntu 24.04 LTS | All hosts |
| Architecture | amd64 | ARM64 support planned |

## Known Compatibility Issues

| Issue | Impact | Workaround |
|-------|--------|------------|
| ApexFusion lags behind Cardano node versions | Cannot run latest Cardano node for ApexFusion | Separate Dockerfiles with independent version pins |
| Mithril not available for ApexFusion | Cannot fast-sync ApexFusion nodes | Use NAS backup restore or full sync |
| ApexFusion uses different Guild fork | Config downloads and tooling differ | Scitz0/guild-operators-apex fork handles this |

## Version Pin Locations

All version pins are in `chains/<chain>/versions.env`:

```
chains/cardano/versions.env      # Cardano versions
chains/apexfusion/versions.env   # ApexFusion versions
chains/midnight/versions.env     # Midnight image version
```

## Upstream References

- [Cardano Node Releases](https://github.com/IntersectMBO/cardano-node/releases)
- [Cardano CLI Releases](https://github.com/IntersectMBO/cardano-cli/releases)
- [ApexFusion Prime Docker](https://github.com/APN-Fusion/prime-docker) — check before upgrading
- [Mithril Releases](https://github.com/input-output-hk/mithril/releases)
- [CNCLI Releases](https://github.com/cardano-community/cncli/releases)
- [Midnight Documentation](https://docs.midnight.network/)
