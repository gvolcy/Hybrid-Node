# Tailscale ACL policy (draft)

Paste into the Tailscale admin console → **Access controls**:
https://login.tailscale.com/admin/acls

Tailnet: `taild80801.ts.net`  
Owner login: Apple Private Relay identity on the tailnet.

## Goals

1. Admin devices (Mac, phone) can reach all servers over Tailscale.
2. Servers can talk to each other (Wazuh, Ollama, k3s ops, SSH mesh).
3. No anonymous / unmatched sources get free rein if you later add users.

## Policy (HuJSON)

Tag servers after saving, or apply tags in the admin Machines UI:

| MagicDNS / hostname | Suggested tag   | SSH port |
|---------------------|-----------------|----------|
| mvolcy (main1)      | `tag:server`    | 4077     |
| mvolcy2 (main2)     | `tag:server`    | 4078     |
| main2 (main3)       | `tag:server`    | 47       |
| main3 (main4)       | `tag:server`    | 48       |
| mvolcy5 (main5)     | `tag:server`    | 408      |
| volcyNAS (main6)    | `tag:server`    | 9790     |
| Gregory’s MacBook Pro | (user device) | 22     |
| iPhone              | (user device)   | —        |

```jsonc
// Hybrid-Node fleet ACL — conservative starter
// Owner identity must match your Tailscale login name exactly.
{
	"tagOwners": {
		"tag:server": ["autogroup:admin"],
	},

	"acls": [
		// Admins (you): full access to everything on the tailnet
		{
			"action": "accept",
			"src":    ["autogroup:admin"],
			"dst":    ["*:*"],
		},

		// All tagged servers may talk to each other (Wazuh agents,
		// Ollama, internal SSH, metrics over Tailscale, etc.)
		{
			"action": "accept",
			"src":    ["tag:server"],
			"dst":    ["tag:server:*"],
		},

		// Optional tighter alternative to the admin *:* rule above:
		// uncomment and remove the admin *:* grant if you want SSH-only
		// from user devices to servers.
		//
		// {
		// 	"action": "accept",
		// 	"src":    ["autogroup:member"],
		// 	"dst":    [
		// 		"tag:server:22",
		// 		"tag:server:47",
		// 		"tag:server:48",
		// 		"tag:server:408",
		// 		"tag:server:4077",
		// 		"tag:server:4078",
		// 		"tag:server:9790",
		// 		"tag:server:443",
		// 		"mvolcy:443"
		// 	],
		// },
	],

	// Optional: Tailscale SSH (separate from OpenSSH). Leave empty
	// unless you enable Tailscale SSH on machines.
	"ssh": [
		{
			"action": "check",
			"src":    ["autogroup:admin"],
			"dst":    ["tag:server"],
			"users":  ["autogroup:nonroot", "root"],
		},
	],
}
```

## Apply steps

1. Open https://login.tailscale.com/admin/acls  
2. Replace policy with the HuJSON above (or merge carefully).  
3. **Save**.  
4. Machines → each Linux host → Edit route settings / tags → add `tag:server`.  
5. From Mac: `ssh main1` … `ssh main6` still work.  
6. From a server: `ssh main1` (Wazuh/agent paths) still work.

## Do not break

- Cardano / Apex / Leios / Midnight **public P2P** uses the internet, not Tailscale — ACL changes here do not close those ports.
- Host UFW still enforces Tailscale+LAN SSH; ACL is defense in depth.

## Rollback

Admin console → Access controls → restore previous policy from history, or set:

```jsonc
{
	"acls": [{"action": "accept", "src": ["*"], "dst": ["*:*"]}],
}
```
