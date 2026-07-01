# Topology & Custom Peers

How to add custom peers and override the full topology for nodes deployed via the
`hybrid-node` chart. The image is Guild-Operators based and uses **P2P** topology
by default.

## Two ways to set peers

| Method | Chart field | Use when |
|--------|-------------|----------|
| Custom peers (simple) | `cardano.customPeers` | Add a few extra `addr:port` peers on top of the managed topology |
| Full topology override | `topologyOverride` | You need complete control (localRoots/publicRoots, valency, groups) |

### 1. Custom peers (simple)

`cardano.customPeers` is a comma-separated `host:port` list injected as the
`CUSTOM_PEERS` env var. The entrypoint merges these into the generated topology.

```yaml
cardano:
  customPeers: "relay1.example.com:6000,relay2.example.com:6000,203.0.113.10:3001"
```

Docker equivalent:

```bash
docker run -d --name cardano-relay \
  -e NETWORK=mainnet -e NODE_MODE=relay \
  -e CUSTOM_PEERS="relay1.example.com:6000,relay2.example.com:6000" \
  ... ghcr.io/gvolcy/hybrid-node:cardano-10.6.3
```

**Typical uses:**
- Point a BP at *only* your own relays (combine with a topology override — see below).
- Add a trusted partner relay to a public relay.
- Pin a specific relay during an incident.

### 2. Full topology override (P2P JSON)

Set `topologyOverride` to a raw P2P `topology.json`. The chart mounts it as a
ConfigMap ([configmap.yaml](../../charts/hybrid-node/templates/configmap.yaml)) and
the node uses it verbatim.

**Relay** — connect to your own relays (localRoots) and the public network
(publicRoots via bootstrap peers):

```yaml
topologyOverride: |
  {
    "localRoots": [
      {
        "accessPoints": [
          { "address": "relay2.example.com", "port": 6000 },
          { "address": "relay3.example.com", "port": 6000 }
        ],
        "advertise": false,
        "trustable": true,
        "valency": 2
      }
    ],
    "publicRoots": [
      {
        "accessPoints": [
          { "address": "backbone.cardano.iog.io", "port": 3001 },
          { "address": "backbone.mainnet.emurgornd.com", "port": 3001 }
        ],
        "advertise": false
      }
    ],
    "useLedgerAfterSlot": 128908821
  }
```

**Block producer** — connect **only** to your own relays, never the public
network. Set `useLedgerAfterSlot` to `-1` so the BP never fetches public peers
from the ledger:

```yaml
topologyOverride: |
  {
    "localRoots": [
      {
        "accessPoints": [
          { "address": "relay1.example.com", "port": 6000 },
          { "address": "relay2.example.com", "port": 6000 }
        ],
        "advertise": false,
        "trustable": true,
        "valency": 2
      }
    ],
    "publicRoots": [],
    "useLedgerAfterSlot": -1
  }
```

> ⚠️ **BP topology rule:** a block producer must peer *only* with your own relays.
> Never list public peers and never expose the BP port publicly (use
> `networkPolicy` + firewall). See [docs/security/firewall.md](../security/firewall.md).

**Key fields:**

| Field | Meaning |
|-------|---------|
| `localRoots[].accessPoints` | Peers you manage; the node keeps `valency` hot connections |
| `advertise` | `true` to gossip this peer to others (usually `false` for private relays/BPs) |
| `trustable` | Trust this group as a bootstrap source |
| `valency` | Number of hot connections to maintain in the group |
| `publicRoots` | Well-known bootstrap relays; `[]` for a BP |
| `useLedgerAfterSlot` | Slot after which to use ledger peers; `-1` disables (BP) |

## Updating topology on a running node

Editing `topologyOverride` (or `customPeers`) and running `helm upgrade` updates
the ConfigMap and triggers a `Recreate` rollout (the node restarts).

```bash
helm upgrade <release> ./charts/hybrid-node -f <values-file>
```

For a **hot reload without restart**, cardano-node re-reads `topology.json` on
`SIGHUP` (P2P dynamic topology). If your ConfigMap is already mounted, you can
update it and signal the process:

```bash
# Update the ConfigMap, wait for the projected file to refresh (~60s), then:
kubectl -n <ns> exec <pod> -c cardano-node -- bash -lc 'pkill -HUP cardano-node'
```

> On a BP, prefer a scheduled `Recreate` rollout during a low-risk window over
> live SIGHUP, and only when relays are healthy.

## Verifying peers

```bash
# Established/hot peer counts from the node
scripts/health/check-peers.sh <node>

# Or query the node's P2P state directly
kubectl -n <ns> exec <pod> -c cardano-node -- \
  bash -lc 'curl -s localhost:12798/metrics | grep -i peer'
```

Confirm the BP sees exactly your relays (no public peers) and that relays show a
healthy inbound/outbound peer count.

## Related

- Chart values: [values-relay-example.yaml](../../charts/hybrid-node/values-relay-example.yaml),
  [values-bp-example.yaml](../../charts/hybrid-node/values-bp-example.yaml)
- BP protection: [docs/security/firewall.md](../security/firewall.md)
- Chain-specific P2P notes: [chains/cardano/README.md](../../chains/cardano/README.md)
