# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Latest  | ✅                 |
| < Latest| ❌                 |

## Reporting a Vulnerability

If you discover a security vulnerability in Hybrid-Node, please report it responsibly:

1. **Do NOT open a public GitHub issue.**
2. Email security concerns to the maintainers directly.
3. Include:
   - Description of the vulnerability
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

## Scope

Security issues we care about:

- **Key material exposure**: Any path where `.skey`, `.vkey`, `.cert`, or pool keys could leak
- **Container escapes**: Privilege escalation from the `guild` user
- **Network exposure**: BP IP leaks, topology misconfigurations
- **Secret injection**: Kubernetes secrets, environment variable leaks in logs
- **Supply chain**: Compromised base images, Guild Operator scripts, or dependencies

## Security Practices

- All pool keys are in `.gitignore` — never committed
- BP nodes use `NetworkPolicy` to restrict ingress to known relay IPs
- The container runs as non-root user `guild` (UID 1000)
- `securityContext.capabilities.drop: ALL` in Helm charts
- Entrypoint sanitizes sensitive env vars from log output
- HEALTHCHECK uses socket + tip query (no key material accessed)
