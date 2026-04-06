# Compatibility Matrix

## Current Versions

| Component | Cardano | ApexFusion | Notes |
|-----------|---------|------------|-------|
| cardano-node | 10.6.3 | 10.1.4 | Source-built from IntersectMBO |
| cardano-cli | 10.15.1.0 | 9.4.1.0 | CLI version must match node era |
| GHC | 9.6.6 | 9.6.6 | Haskell compiler |
| Cabal | 3.12.1.0 | 3.12.1.0 | Build tool |
| Mithril client | 0.12.38 | — | Not available for ApexFusion |
| Mithril signer | 0.3.7 | — | Not available for ApexFusion |
| CNCLI | 6.7.0 | 6.7.0 | Leader logs, PoolTool |
| nview | 0.13.0 | 0.13.0 | TUI node monitor |
| txtop | 0.14.0 | 0.14.0 | Mempool viewer |
| Guild Operators | cardano-community/master | Scitz0/main | Different forks |
| Base image | debian:bookworm-slim | debian:bookworm-slim | Shared |
| Haskell image | blinklabs-io/haskell:9.6.6-3.12.1.0-3 | Same | Build stage only |

## Midnight

| Component | Version | Notes |
|-----------|---------|-------|
| midnight-node | 0.22.3 | Pre-built from midnightntwrk |
| cardano-node (companion) | Latest preview | IntersectMBO official image |
| db-sync | Latest | IntersectMBO official image |
| ogmios | Latest | cardanosolutions official image |
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
