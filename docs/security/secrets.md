# Secrets Management

## Classification

| Secret | Sensitivity | Where It Lives | Backup Location |
|--------|-------------|----------------|-----------------|
| **Cold keys** (`cold.skey`, `cold.vkey`, `cold.counter`) | 🔴 Critical | main6 (NAS, offline only) | USB cold storage |
| **KES key** (`kes.skey`) | 🔴 Critical | BP host (main1) only | main6 after rotation |
| **VRF key** (`vrf.skey`) | 🔴 Critical | BP host (main1) only | main6 |
| **Operational cert** (`op.cert`) | 🟡 High | BP host (main1) only | main6 |
| **Payment keys** (`payment.skey`) | 🔴 Critical | main6 (NAS, offline only) | USB cold storage |
| **Stake keys** (`stake.skey`) | 🔴 Critical | main6 (NAS, offline only) | USB cold storage |
| **Pool metadata** (`poolMetaData.json`) | 🟢 Public | GitHub / web server | — |
| **Topology (BP)** | 🟡 High | BP host only, not in repo | — |
| **Midnight validator keys** | 🔴 Critical | K3s secret (`midnight-node-keys`) | main6 |

## Key Principles

1. **Cold keys never touch a hot machine** — generate and sign on main6 (air-gapped preferred)
2. **Only hot keys on the BP** — `kes.skey`, `vrf.skey`, `op.cert`
3. **Relays have no keys** — they are stateless from a key perspective
4. **Nothing secret in git** — `.gitignore` blocks `*.skey`, `*.vkey`, `*.cert`, `*.env`, etc.
5. **Kubernetes secrets are external** — never in manifests, always via `kubectl create secret`

## File Layout on BP

A block producer needs **only the hot key set**. Nothing else under `priv/`
should be on an internet-connected machine.

```text
/opt/cardano/cnode/priv/pool/<pool>/
├── kes.skey / hot.skey   ← hot key (rotated every ~62 epochs)
├── vrf.skey              ← VRF key (permanent per pool)
├── op.cert               ← operational certificate (public; renewed with KES)
├── *.vkey                ← verification keys (public; fine to keep)
└── (NO cold.skey, NO cold.counter, NO calidus.skey, NO priv/wallet/*.skey)
```

Everything else — `cold.skey`, `cold.counter*`, `calidus.skey`, and the **entire
`priv/wallet/` tree** (`payment.skey`, `stake.skey`, `drep.skey`, `ms_*.skey`,
`cc-cold.skey`, `cc-hot.skey`) — is operator material that belongs on the
air-gapped machine (main6) and USB cold storage **only**. The node never reads
any of it.

## Auditing & At-rest Protection

The offline-only keys (`cold.skey`, `cold.counter*`, `calidus.skey`, and the
entire `priv/wallet/` tree) must be protected at rest by **one** of:

- **A) Air-gap** — keys live only on main6, not on the BP at all (strongest).
- **B) CNTools encryption** — keys stay on the BP but GPG-symmetric
  ("password") encrypted, i.e. present as `<name>.skey.gpg` with no plaintext
  sibling. This is the chosen model here; it's lower-friction than air-gap.

The hot set (`kes/hot.skey`, `vrf.skey`) **must stay plaintext** — the node
reads it at runtime.

```bash
# READ-ONLY audit — exits non-zero if any sensitive key is in plaintext.
# `enc` = encrypted at rest (ok), `hot` = required plaintext (ok), `PLAIN` = risk.
# Wire into CI / a CronJob / Alertmanager.
NAMESPACES="cmainnet-bp haiti-bp" ./scripts/security/audit-bp-keys.sh
```

### CNTools encryption (option B — the easy path)

CNTools encrypts/decrypts keys with a passphrase on demand. After **any**
operation that decrypts keys (KES rotation, wallet/pool actions), re-lock them:

```text
cntools.sh  →  [w] Wallet / [p] Pool  →  Encrypt   (repeat per wallet/pool)
```

> ⚠️ CNTools leaves keys **plaintext** after a Decrypt until you run Encrypt
> again. A plaintext `cold.skey`/`payment.skey` on a live BP is the same
> exposure as never encrypting. Always re-encrypt after use, and run the audit
> to confirm `0 sensitive key(s) in PLAINTEXT`.

Keep the passphrase **off** the BP host (password manager / your head), and a
copy of the keys on main6 + USB cold storage in case the passphrase is lost.

### Air-gap evacuation (option A — stronger)

If you prefer keys never touch the hot host, evacuate them to an encrypted
archive and remove them from the pod:

```bash
# step 1 — archive + verify only (no deletion):
./scripts/security/evacuate-cold-keys.sh cmainnet-bp
# step 2 — after copying the .gpg to main6 AND a USB stick, delete from pod:
./scripts/security/evacuate-cold-keys.sh cmainnet-bp '' --remove
```

`evacuate-cold-keys.sh` is safe by default: it tars `priv/` out of the pod,
encrypts it, verifies it decrypts, and only deletes the offline-only secrets
with `--remove` after you confirm an offline copy exists. It always leaves
`kes/hot.skey`, `vrf.skey`, `op.cert` and the public `*.vkey` files in place.

> ⚠️ **Never run `--remove` until the encrypted archive is verified on main6 and
> on USB cold storage.** Cold/payment/stake keys are irrecoverable if lost.

## KES Key Rotation

KES keys expire every ~62 epochs (~62 days). You **must** rotate before expiry.

```bash
# 1. On main6 (offline machine with cold keys):
cardano-cli node new-counter \
  --cold-verification-key-file cold.vkey \
  --counter-value <new-counter> \
  --operational-certificate-issue-counter-file cold.counter

cardano-cli node key-gen-KES \
  --verification-key-file kes.vkey \
  --signing-key-file kes.skey

cardano-cli node issue-op-cert \
  --kes-verification-key-file kes.vkey \
  --cold-signing-key-file cold.skey \
  --operational-certificate-issue-counter-file cold.counter \
  --kes-period <current-kes-period> \
  --out-file op.cert

# 2. Copy kes.skey and op.cert to BP (main1):
scp kes.skey op.cert main1:/opt/cardano/cnode/priv/pool/VOLCY/

# 3. Restart BP:
ssh main1 'docker restart cardano-bp'

# 4. Verify:
scripts/health/check-kes.sh cardano-bp
```

## Kubernetes Secrets

### Create secrets for K3s deployments

```bash
# Cardano BP keys
kubectl create secret generic cardano-bp-keys \
  --from-file=kes.skey=/path/to/kes.skey \
  --from-file=vrf.skey=/path/to/vrf.skey \
  --from-file=op.cert=/path/to/op.cert \
  -n cardano

# Midnight validator keys
kubectl create secret generic midnight-node-keys \
  --from-literal=aura-key='0x...' \
  --from-literal=grandpa-key='0x...' \
  --from-literal=sidechain-key='0x...' \
  -n midnight
```

### Secret references in manifests

```yaml
# In K3s manifests, reference secrets by name — never inline values
volumes:
  - name: pool-keys
    secret:
      secretName: cardano-bp-keys
      defaultMode: 0400
```

## What .gitignore Blocks

```
*.skey
*.vkey
*.cert
*.counter
cold.*
kes.*
vrf.*
op.*
opcert.*
*secret*
*key.json
.env
.env.*
*.env
*-secret.yaml
*-secrets.yaml
id_rsa
id_ed25519
*.pem
*.gpg
*.asc
```

## ApexFusion Secrets

ApexFusion uses the same key types as Cardano (it runs cardano-node). The same
key management practices apply:

- Same KES/VRF/op.cert rotation process
- Keys stored in `/opt/cardano/cnode/priv/pool/<POOL_NAME>/`
- Cold keys on main6 only

## Backup Encryption

For sensitive backups to main6:

```bash
# Encrypt before sending
tar czf - /opt/cardano/cnode/priv/ | \
  gpg --symmetric --cipher-algo AES256 -o pool-keys-backup.tar.gz.gpg

# Send to NAS
scp pool-keys-backup.tar.gz.gpg main6:/backup/keys/encrypted/

# Restore
gpg -d pool-keys-backup.tar.gz.gpg | tar xzf - -C /restore/path/
```
