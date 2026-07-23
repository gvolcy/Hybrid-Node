# Server Security Hardening (Fleet)

Security posture for **main1–main6** (Linux) and notes for **main7** (MacBook).
Implemented 2026-07-22 / 2026-07-23. Complements [`firewall.md`](firewall.md).

## Scope

| Host   | Role (short)              | SSH port |
|--------|---------------------------|----------|
| main1  | BP / Wazuh manager        | 4077     |
| main2  | Testnets / Leios BPs      | 4078     |
| main3  | Relays / Discord bots     | 47       |
| main4  | Relays                    | 48       |
| main5  | Relays / AI               | 408      |
| main6  | NAS / backups             | 9790     |
| main7  | MacBook (`gvolcy`)        | 22 (TS)  |

Access path: **Tailscale MagicDNS** (`~/.ssh/config`). Do not expose SSH to the public internet.

## Stack (what we installed)

### 1. Fail2ban (main1–main6)

- SSH jail on each host’s real SSH port
- `maxretry=3`, `bantime=2h`
- `ignoreip` includes localhost, Tailscale (`100.64.0.0/10`), LAN (`192.168.0.0/16`), and known admin public IPs

### 2. SSH hardening (main1–main6)

Drop-in `/etc/ssh/sshd_config.d/99-hardening.conf`:

- `PasswordAuthentication no`
- `PermitRootLogin no`
- Public-key only

### 3. UFW — SSH Tailscale + LAN only (2026-07-23)

SSH ports allow inbound only from:

- `100.64.0.0/10` (Tailscale)
- `192.168.0.0/16` (LAN break-glass)
- Tailscale IPv6 `fd7a:115c:a1e0::/48` where applicable

Removed public `Anywhere` SSH allows (and leftover public-IP SSH allows on main1/main3).

**Left public on purpose:** Cardano / ApexFusion / Leios / Midnight P2P and NodePorts, Blockfrost, Aquarium `9101`, Icebreaker `3000`, Iagon `1024`, etc. Relays must accept arbitrary internet peers.

See [`firewall.md`](firewall.md) for metrics/private-port history.

### 4. Unattended upgrades

- `unattended-upgrades` enabled for security patches
- **No automatic reboot** (rolling reboot remains manual / ops playbook)

### 5. Wazuh (all-in-one on main1)

| Piece        | Location                                      |
|--------------|-----------------------------------------------|
| Manager      | main1                                         |
| Indexer      | main1                                         |
| Dashboard    | main1; Tailscale Serve → `https://mvolcy.taild80801.ts.net/` |
| Agents       | main2–main6, pinned **4.12.0** (held)         |
| Credentials  | `/root/wazuh-credentials.txt` on main1 (`admin`) |

Dashboard notes:

- Prefer Tailscale Serve (port 443), not raw `:8443`
- Cert SANs include MagicDNS / Tailscale IP
- If UI shows “offline”, check `wazuh-wui` API password sync (recreate defaults + re-sync if needed)

### 6. Wazuh alert tuning

`/var/ossec/etc/rules/local_rules.xml` on main1:

- Promiscuous-mode noise (`80790`) muted to level 0 (common with Tailscale/Docker/k3s)
- Known-admin sudo / PAM lowered so routine ops do not dominate MITRE views

MITRE ATT&CK is enabled; most “attacks” observed in ops windows are mapped admin activity (sudo, SSH, PAM), not intrusion.

### 7. Discord alerts (level ≥ 10)

Custom integration on main1:

- Scripts: `/var/ossec/integrations/custom-discord` + `custom-discord.py`
- Config: single `<integration><name>custom-discord</name>` block in `ossec.conf` (level 10, JSON)
- Webhook file: `/var/ossec/etc/discord_webhook.url` (mode `640`, `root:wazuh`)

Webhook source: same Discord channel webhook used by the My-Local-AI bots
(`discord-webhook-script` ConfigMap on main3 in `openclaw-marketing` /
`hermes-business`). **Do not commit the URL** to git.

After changing the webhook:

```bash
ssh main1 'sudo systemctl restart wazuh-manager'
```

Test ping (from a host that has the URL, or paste into a one-off):

```bash
# Prefer using the installed file on main1
ssh main1 'sudo python3 - <<'"'"'PY'"'"'
import json, urllib.request
from pathlib import Path
url = Path("/var/ossec/etc/discord_webhook.url").read_text().strip()
req = urllib.request.Request(
    url,
    data=json.dumps({"username": "Wazuh", "content": "Wazuh Discord test"}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "DiscordBot"},
)
print(urllib.request.urlopen(req, timeout=20).status)
PY'
```

## Mac (main7)

Hostname: `gregorys-macbook-pro` / `MacBookPro`, user `gvolcy`, Tailscale MagicDNS.
`ssh main7` works with Linux `id_ed25519` (verified 2026-07-23).

Baseline (confirmed): FileVault **On**, firewall **enabled**, Tailscale online.

Notes from setup:

- `authorized_keys` must contain main1’s `~/.ssh/id_ed25519.pub`
- macOS `sshd_config` **`AllowUsers` must include `gvolcy`** (a prior list of Linux names blocked login)
- Do not edit main1’s `/etc/ssh/sshd_config` when fixing the Mac
- No pool cold keys / seeds on the laptop; keep auto updates on

## Explicitly not changed

- Cardano / Apex / Leios / Midnight P2P reachability
- k3s `hostPort` / NodePort behavior (kube-proxy bypasses UFW for published ports)
- Pool cold-key locations (ops discipline; see secrets hygiene below)

## Secrets hygiene (ops)

- Keep cold keys / wallet seeds / API tokens out of home dirs on online nodes when possible
- Prefer password manager or encrypted offline storage (main6 / USB)
- Discord webhook stays in `/var/ossec/etc/discord_webhook.url` and k8s ConfigMaps — rotate in Discord if leaked
- Never commit `.env`, `.skey`, or webhook URLs

### Filename audit (2026-07-23)

Names only — no contents read. Notable findings:

| Host  | Finding | Action |
|-------|---------|--------|
| main2 | Apex `kes_rotation_emergency/cold.skey`, Midnight `cold.skey` / `payment.skey` (mode `600`) | Prefer offline copy; remove from online disk when unused |
| main6 | Same Apex/Midnight cold keys were **world-writable (`777`)** | Modes tightened to `700` dirs / `600` `.skey` |
| main1–5 | Many operational `.env` files under home | Expected for node ops; keep gitignored |
| all   | User SSH private keys under `~/.ssh` | Normal; do not copy cold pool keys beside them |

SSH private keys and Ollama keys under home are normal. Focus cleanup on **cold.skey** copies that are not required for live ops.

## Quick health checks

```bash
# SSH still works over Tailscale
for h in main1 main2 main3 main4 main5 main6; do
  ssh -o BatchMode=yes -o ConnectTimeout=6 "$h" "echo OK \$(hostname)"
done

# No public SSH Anywhere left
for h in main1 main2 main3 main4 main5 main6; do
  echo "=== $h ==="
  ssh -o BatchMode=yes "$h" "sudo ufw status | grep -iE 'ssh|4077|4078| 47 | 48 |408|9790' || true"
done

# Wazuh agents
ssh main1 'sudo /var/ossec/bin/agent_control -l'

# Fail2ban
ssh main1 'sudo fail2ban-client status'
```

## Related docs

- [`firewall.md`](firewall.md) — UFW principles and private metrics ports
- [`../operations/restart-procedures.md`](../operations/restart-procedures.md) — rolling reboot
- [`.github/SECURITY.md`](../../.github/SECURITY.md) — vulnerability reporting
