# Contributing to Hybrid-Node

Thanks for your interest in contributing! Hybrid-Node powers 17+ production blockchain nodes across Cardano, ApexFusion, and Midnight networks.

## Getting Started

1. **Fork** the repo and clone locally
2. Create a feature branch: `git checkout -b feat/my-change`
3. Make your changes
4. Test locally (see below)
5. Push and open a PR against `main`

## Project Structure

```
Hybrid-Node/
├── bin/entrypoint.sh          # Unified entrypoint (1100+ lines)
├── platform/docker/Dockerfile # Multi-stage Docker build
├── chains/                    # Chain-specific configs & K3s manifests
│   ├── cardano/
│   ├── apexfusion/
│   └── midnight/
├── charts/hybrid-node/        # Helm chart
├── docs/                      # Architecture & deployment docs
└── .github/workflows/         # CI (build + lint)
```

## Development

### Prerequisites

- Docker (with buildx for multi-arch)
- `shellcheck` for linting: `sudo apt install shellcheck`
- K3s or kubectl (for testing manifests)

### Build locally

```bash
make build                    # Build Docker image (amd64)
make build-multi              # Build multi-arch (amd64 + arm64)
```

### Run locally

```bash
make run-relay                # Spin up a mainnet relay
make shell                    # Open a shell in the container
```

### Lint

```bash
shellcheck -x -s bash bin/entrypoint.sh
```

## What We're Looking For

### High Priority
- **New chain support** — Adding more Cardano-family or Substrate chains
- **Entrypoint hardening** — Signal handling, error recovery, edge cases
- **Monitoring improvements** — Prometheus exporters, alerting rules
- **Helm chart enhancements** — More configurable values, better defaults

### Welcome
- Documentation improvements
- K3s manifest examples for different topologies
- Performance tuning (RTS flags, resource limits)
- Security hardening (NetworkPolicy, seccomp, AppArmor)

### Please Discuss First
- Architectural changes to entrypoint.sh
- New environment variables
- Breaking changes to Helm values

Open an [issue](https://github.com/gvolcy/Hybrid-Node/issues) to discuss before starting large changes.

## Code Style

- **Shell scripts**: Follow [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html). Must pass ShellCheck.
- **YAML**: 2-space indent. Use `yamllint -d relaxed`.
- **Dockerfile**: Follow [Hadolint](https://github.com/hadolint/hadolint) recommendations.
- **Commits**: Use [Conventional Commits](https://www.conventionalcommits.org/) — `feat:`, `fix:`, `docs:`, `chore:`.

## Testing

Before submitting a PR:

1. **ShellCheck passes** on any modified `.sh` files
2. **Docker build succeeds**: `make build`
3. **Container starts**: `make run-relay` → check logs for healthy startup
4. **No secrets exposed** — never commit keys, topology with BP IPs, or pool credentials

## Production Context

This isn't a toy project. Changes to `entrypoint.sh` or the Dockerfile affect production nodes handling real ADA delegation. Please:

- Test thoroughly before submitting
- Don't introduce breaking changes to env var behavior
- Preserve backward compatibility with existing K3s deployments
- Be mindful of the 280-second graceful shutdown window

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).

---

Questions? Open an issue or reach out to [@Gvolcy](https://x.com/Gvolcy).
