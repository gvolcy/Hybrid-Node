# Host Firewall (UFW) Hardening

Host-level firewall policy for the Hybrid-Node fleet. This complements the
in-cluster Kubernetes `NetworkPolicy` resources (`charts/hybrid-node/templates/networkpolicy.yaml`)
— NetworkPolicies govern pod-to-pod traffic; UFW governs what the host exposes
to the outside world.

## Principles

1. **Default deny incoming.** Every host runs `ufw` with
   `Default: deny (incoming), allow (outgoing)`.
2. **SSH and Tailscale are never restricted by automation.** Each host has a
   non-standard SSH port and is reached over Tailscale (`100.64.0.0/10`).
   These rules are treated as untouchable to avoid lockout.
3. **Public only what must be public.** Cardano / ApexFusion relay P2P ports,
   relay NodePorts, and public services (e.g. Blockfrost) stay open to
   `Anywhere`. Relays *must* accept inbound connections from arbitrary
   internet peers — that is their function.
4. **Management/metrics ports are private-only.** Prometheus exporters
   (`127xx`), Prometheus/Alertmanager/Pushgateway UIs, EKG, and other
   operational endpoints are restricted to private networks
   (`100.64.0.0/10` Tailscale + `192.168.0.0/16` LAN). Local scraping happens
   over `localhost` and is unaffected.
5. **Kubernetes-managed ports bypass UFW.** k3s/kube-proxy install their own
   iptables chains, so `hostPort`/`NodePort` services (relay P2P, the Mithril
   relay on `:3132`) keep working regardless of UFW. Do not rely on UFW to
   gate k8s-published ports — use NetworkPolicy for those.

## Host-specific constraints

- **main3** runs **Blockfrost** (`:3000`) which connects to the local
  **mainnet2 relay** (`:3003`). Both must remain reachable. Never restrict
  `3000`/`3003` on main3.
- **main4 / main3** host the **Mithril relay** (Squid, `hostPort 3132`).
  This is k8s-managed and bypasses UFW; the relay's ACL (in
  `chains/cardano/k3s/mithril-relay.yaml`) is what restricts it to BP hosts.
- **main1** runs the mainnet block producers plus Docker (many `br-*`
  bridges). As of 2026-06-01 it is firewalled (was the last host without UFW).
  Its config uses the standard `ufw-docker` integration
  (`/etc/ufw/after.rules` routes the `DOCKER-USER` chain through
  `ufw-user-forward`, RETURNing private ranges), so Docker-published ports are
  governed by `ufw route` rules rather than plain `ufw allow`.
  Note: `DEFAULT_FORWARD_POLICY` is currently `allow (routed)`, so published
  Docker ports (incl. Postgres `aquarium-pg:5432`) are reachable from any
  routable source. main1 is behind NAT, so today that means LAN + Tailscale,
  not the open internet. Tightening 5432 et al. to private-only is a tracked
  follow-up (Layer 2).

## What was hardened (2026-06-01)

Converted the following from `ALLOW IN Anywhere` to private-only
(`100.64.0.0/10` + `192.168.0.0/16`). These were latent exposure: either
scraped locally via `localhost` or not bound on the host at all.

| Host  | Ports moved to private-only |
|-------|------------------------------|
| main1 | re-enabled UFW (default deny incoming); `ufw route allow` for node metrics `12798`/`12799` restricted to Tailscale + LAN |
| main2 | `8782`, `8783` (BP EKG), `11434` (Ollama) |
| main3 | `12780`, `12784`, `12785`, `12786`, `12787` (metrics), `9090` (Prometheus) |
| main4 | `12780`, `12784`, `12785`, `12786`, `12788`, `12790`, `12795`, `12796`, `12798`, `12799` (metrics), `9093` (Alertmanager), `9300` (Pushgateway) |
| main5 | `12798`, `12799`, `12803`, `12813` (apex metrics) |

Left public (unchanged): all SSH ports, Cardano/ApexFusion relay P2P ports,
relay NodePorts, Blockfrost (`3000`), Midnight NodePorts, and third-party
(Xerberus) RPC/P2P ports.

On main1, the real cardano metrics are scraped via the `aquarium` container
(`:9101/actuator/prometheus`), not `:12798` (nothing binds 12798/12799 on the
host); the route allows are forward-compatible no-ops today.

## How to restrict a port to private networks

`ufw` evaluates rules top-down, first match wins. Add the private allows, then
delete the `Anywhere` rule:

```bash
# Back up first
sudo cp /etc/ufw/user.rules  /root/ufw-user.rules.bak.$(date +%F_%H%M%S)
sudo cp /etc/ufw/user6.rules /root/ufw-user6.rules.bak.$(date +%F_%H%M%S)

P=12788   # example: a metrics port
sudo ufw allow from 100.64.0.0/10  to any port $P proto tcp comment 'metrics private (Tailscale)'
sudo ufw allow from 192.168.0.0/16 to any port $P proto tcp comment 'metrics private (LAN)'
sudo ufw delete allow $P/tcp      # removes the public (Anywhere) rule, v4 + v6
```

## Rollback

Each hardening run backs up the rule files. To revert a host completely:

```bash
sudo cp /root/ufw-user.rules.bak.<timestamp>  /etc/ufw/user.rules
sudo cp /root/ufw-user6.rules.bak.<timestamp> /etc/ufw/user6.rules
sudo ufw reload
```

## Reference: relay vs BP exposure (best practice)

- **Relay:** Cardano P2P port open to `Anywhere` (or trusted ranges).
- **Block producer:** Cardano P2P port open **only from your relay IPs**.
  The BPs in this fleet run in k3s and are fronted by relays on separate
  hosts; BP P2P exposure should be limited to relay source IPs at the host
  firewall where the BP node port is published.
