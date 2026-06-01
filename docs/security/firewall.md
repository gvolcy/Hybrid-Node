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
  bridges) and currently has **no UFW**. Adding UFW there needs care because
  UFW does not filter Docker-published ports without extra configuration
  (`/etc/ufw/after.rules` DOCKER-USER chain). Treat separately.

## What was hardened (2026-06-01)

Converted the following from `ALLOW IN Anywhere` to private-only
(`100.64.0.0/10` + `192.168.0.0/16`). These were latent exposure: either
scraped locally via `localhost` or not bound on the host at all.

| Host  | Ports moved to private-only |
|-------|------------------------------|
| main2 | `8782`, `8783` (BP EKG), `11434` (Ollama) |
| main3 | `12780`, `12784`, `12785`, `12786`, `12787` (metrics), `9090` (Prometheus) |
| main4 | `12780`, `12784`, `12785`, `12786`, `12788`, `12790`, `12795`, `12796`, `12798`, `12799` (metrics), `9093` (Alertmanager), `9300` (Pushgateway) |
| main5 | `12798`, `12799`, `12803`, `12813` (apex metrics) |

Left public (unchanged): all SSH ports, Cardano/ApexFusion relay P2P ports,
relay NodePorts, Blockfrost (`3000`), Midnight NodePorts, and third-party
(Xerberus) RPC/P2P ports.

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
