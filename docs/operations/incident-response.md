# Incident Response

## Severity Levels

| Level | Description | Response Time | Example |
|-------|-------------|---------------|---------|
| **P1 — Critical** | Block production stopped | Immediate | BP down, KES expired, all relays down |
| **P2 — High** | Degraded but operational | < 1 hour | Single relay down, low peer count |
| **P3 — Medium** | Performance issue | < 4 hours | High memory, slow sync, disk warning |
| **P4 — Low** | Non-urgent | < 24 hours | Log noise, non-critical tool failure |

## Quick Diagnosis

```bash
# Run all health checks
scripts/health/check-all.sh <container-name>

# Check container status
docker ps -a | grep -E 'cardano|apex'

# Check recent logs
docker logs --tail 100 <container-name>

# Check system resources
free -h && df -h /opt/cardano/cnode/db && uptime
```

## Common Incidents

### BP not producing blocks

1. Check if BP is running: `docker ps | grep bp`
2. Check sync status: `scripts/health/check-sync.sh cardano-bp`
3. Check KES expiry: `scripts/health/check-kes.sh cardano-bp`
4. Check peer connections: `scripts/health/check-peers.sh cardano-bp`
5. Check relay connectivity: verify relays are synced and peered

**If KES expired:**
```bash
# Rotate KES key (requires cold key on main6)
# 1. Generate new KES key on main6 (offline)
# 2. Create new operational certificate
# 3. Copy kes.skey and op.cert to BP
# 4. Restart BP
docker restart cardano-bp
```

### Node won't start / crash loop

1. Check logs: `docker logs --tail 200 <container>`
2. Common causes:
   - **Corrupted DB** → delete DB, re-sync via Mithril or backup
   - **Port conflict** → check `netstat -tlnp | grep <port>`
   - **Memory OOM** → increase container memory limit
   - **Config error** → check NETWORK, NODE_MODE env vars
   - **Socket permission** → check `/opt/cardano/cnode/sockets/` permissions

### All relays down

1. **Do NOT panic** — BP can survive briefly without relays
2. Start relays one at a time, wait for sync
3. Check firewall rules, DNS, ISP issues
4. If relays cannot sync, check upstream Cardano network status

### Disk full

1. Check what's consuming space: `du -sh /opt/cardano/cnode/*`
2. Clean old logs: `find /opt/cardano/cnode/logs -mtime +7 -delete`
3. Clean old Guild DB: `rm -f /opt/cardano/cnode/guild-db/cncli*.db-journal`
4. Consider expanding the volume
5. Restart after freeing space

### Network partition (node can't find peers)

1. Check DNS resolution: `dig relay.cardano.example.com`
2. Check firewall: `ss -tlnp | grep 3001`
3. Check topology: ensure peers are correct for the network
4. Check Tailscale: `tailscale status` (for BP-relay connectivity)
5. Try adding manual peers: `-e CUSTOM_PEERS=addr:port`

## Post-Incident

After resolving any P1/P2 incident:

1. Document what happened, when, and what fixed it
2. Check if monitoring would have caught it earlier
3. Update alert thresholds if needed
4. Verify backup integrity
5. Run `scripts/health/check-all.sh` on all nodes
