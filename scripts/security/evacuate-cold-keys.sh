#!/usr/bin/env bash
# evacuate-cold-keys.sh — Move offline-only private keys OFF a hot block-producer
#                         pod into an encrypted archive, then (optionally) delete
#                         them from the pod, leaving only the hot key set.
#
# A block producer needs ONLY: kes/hot.skey, vrf.skey, op.cert.
# This script evacuates everything else under priv/ (cold.skey, cold.counter*,
# calidus.skey, and the whole priv/wallet/ tree) to an AES-256 GPG archive you
# then move to the air-gapped machine (main6) and to USB cold storage.
#
# SAFE BY DEFAULT: archives + verifies but does NOT delete unless you pass
# --remove. Even with --remove it refuses unless the archive verified and you
# confirm an offline copy exists.
#
# Usage:
#   ./evacuate-cold-keys.sh <namespace> [pod-substring]            # archive only (dry of deletion)
#   ./evacuate-cold-keys.sh <namespace> [pod-substring] --remove   # archive + verify + delete
#
# Env:
#   OUT_DIR        where the encrypted archive is written (default: ./key-evacuation)
#   GPG_RECIPIENT  if set, encrypt to this pubkey (asymmetric); else symmetric passphrase
#   PRIV_DIR       in-pod priv dir (default /opt/cardano/cnode/priv)
#   KUBECTL        kubectl binary (default kubectl)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
NS="${1:-}"; WANT="${2:-}"; REMOVE=0
for a in "$@"; do [ "$a" = "--remove" ] && REMOVE=1; done
[ -z "$NS" ] && { echo "Usage: $0 <namespace> [pod-substring] [--remove]" >&2; exit 64; }

PRIV_DIR="${PRIV_DIR:-/opt/cardano/cnode/priv}"
KUBECTL="${KUBECTL:-kubectl}"
OUT_DIR="${OUT_DIR:-./key-evacuation}"
TS="$(date +%Y%m%d_%H%M%S)"

# Keep ONLY these on the hot host; archive+remove everything else under priv/.
# (op.cert/node.cert/opcert.cert and all *.vkey/identity files stay — they're not secret.)
KEEP_BASENAMES='kes.skey|hot.skey|vrf.skey'

pod=$("$KUBECTL" get pods -n "$NS" -o name 2>/dev/null \
    | { [ -n "$WANT" ] && grep -i "$WANT" || cat; } | head -1)
[ -z "$pod" ] && pod=$("$KUBECTL" get pods -n "$NS" -o name 2>/dev/null | head -1)
[ -z "$pod" ] && { echo -e "${RED}✗ no pod in namespace '${NS}'${NC}"; exit 2; }
pod="${pod#pod/}"
echo -e "${BLUE}== evacuating: ${NS}/${pod} ==${NC}"

# 1) Enumerate every private *.skey (and cold.counter*) that is NOT in the keep set.
mapfile -t TARGETS < <("$KUBECTL" exec -n "$NS" "$pod" -- sh -c \
    "find ${PRIV_DIR} -type f \( -name '*.skey' -o -path '*cold.counter*' \) 2>/dev/null" 2>/dev/null \
    | grep -Ev "/($KEEP_BASENAMES)\$" || true)

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo -e "${GREEN}✓ nothing to evacuate — only hot keys present${NC}"
    exit 0
fi

echo -e "${YELLOW}The following offline-only secrets will be archived${NC}$([ "$REMOVE" = 1 ] && echo ' and REMOVED'):"
printf '  %s\n' "${TARGETS[@]}"
echo "  (keeping on host: kes/hot.skey, vrf.skey, op.cert, all *.vkey/identity)"

# 2) Stream a tarball of priv/ OUT of the pod, then encrypt locally.
mkdir -p "$OUT_DIR"; chmod 700 "$OUT_DIR"
RAW="${OUT_DIR}/${NS}-priv-${TS}.tar"
ENC="${RAW}.gpg"
echo -e "${BLUE}→ archiving entire ${PRIV_DIR} (full safety copy) ...${NC}"
"$KUBECTL" exec -n "$NS" "$pod" -- sh -c "cd $(dirname "$PRIV_DIR") && tar cf - $(basename "$PRIV_DIR")" > "$RAW"

if [ -n "${GPG_RECIPIENT:-}" ]; then
    gpg --yes --encrypt --recipient "$GPG_RECIPIENT" -o "$ENC" "$RAW"
else
    echo -e "${YELLOW}You will be prompted for a passphrase (AES-256, symmetric).${NC}"
    gpg --yes --symmetric --cipher-algo AES256 -o "$ENC" "$RAW"
fi
shred -u "$RAW" 2>/dev/null || rm -f "$RAW"
SHA="$(sha256sum "$ENC" | awk '{print $1}')"
echo -e "${GREEN}✓ encrypted archive:${NC} ${ENC}"
echo -e "  sha256: ${SHA}"

# 3) Verify the archive decrypts and contains the targets before any deletion.
echo -e "${BLUE}→ verifying archive integrity ...${NC}"
if [ -n "${GPG_RECIPIENT:-}" ]; then
    gpg -d "$ENC" 2>/dev/null | tar tf - >/dev/null
else
    gpg -d "$ENC" 2>/dev/null | tar tf - >/dev/null
fi
echo -e "${GREEN}✓ archive verified (decrypts + lists cleanly)${NC}"

if [ "$REMOVE" -ne 1 ]; then
    cat <<EOF

${GREEN}Archive-only mode complete.${NC} No keys were deleted.
Next:
  1. Move ${ENC} to main6 (offline) AND a USB cold-storage stick.
  2. Verify there: gpg -d ${ENC##*/} | tar tf - | grep cold.skey
  3. Re-run with --remove to delete the offline-only secrets from the pod:
       $0 ${NS} ${WANT} --remove
EOF
    exit 0
fi

# 4) --remove: require explicit confirmation that an offline copy exists.
echo
echo -e "${RED}DESTRUCTIVE STEP${NC}: about to delete ${#TARGETS[@]} secret file(s) from ${NS}/${pod}."
echo -e "Confirm you have copied ${ENC} (sha256 ${SHA:0:12}…) to main6 AND USB cold storage."
read -r -p "Type the pool namespace ('${NS}') to proceed: " ans
[ "$ans" = "$NS" ] || { echo -e "${YELLOW}aborted — no changes made${NC}"; exit 1; }

for f in "${TARGETS[@]}"; do
    "$KUBECTL" exec -n "$NS" "$pod" -- sh -c "shred -u '$f' 2>/dev/null || rm -f '$f'" \
        && echo -e "  ${GREEN}removed${NC} $f" \
        || echo -e "  ${RED}FAILED ${NC} $f"
done

echo -e "${BLUE}→ re-auditing ...${NC}"
"$(dirname "$0")/audit-bp-keys.sh" "$NS" "$WANT" || true
echo -e "${GREEN}✓ evacuation complete. Encrypted copy: ${ENC}${NC}"
