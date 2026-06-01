#!/usr/bin/env bash
# audit-bp-keys.sh — Audit a block-producer pod for private keys that must NOT
#                    live on a hot (internet-connected) machine.
#
# READ-ONLY. Makes no changes. Exits non-zero if any forbidden key is found,
# so it can be wired into CI / a CronJob / Alertmanager.
#
# Usage:
#   ./audit-bp-keys.sh <namespace> [pod-substring]
#   ./audit-bp-keys.sh cmainnet-bp
#   ./audit-bp-keys.sh haiti-bp haiti
#   NAMESPACES="cmainnet-bp haiti-bp" ./audit-bp-keys.sh        # audit several
#
# A block producer node only needs the HOT key set:
#   priv/pool/<pool>/{kes|hot}.skey, vrf.skey, op.cert (or node.cert/opcert.cert)
# Everything else under priv/ — cold.skey, cold.counter, calidus.skey, and the
# entire priv/wallet/ tree (payment/stake/drep/cc-cold/cc-hot/ms_* .skey) —
# is operator material that belongs on the air-gapped machine (main6) only.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PRIV_DIR="${PRIV_DIR:-/opt/cardano/cnode/priv}"
KUBECTL="${KUBECTL:-kubectl}"

# Private-key files that are FORBIDDEN on a hot BP (regex over basename/path).
FORBIDDEN_REGEX='(^|/)(cold\.skey|cold\.counter([._].*)?|calidus\.skey|payment\.skey|stake\.skey|drep\.skey|ms_[a-z]+\.skey|cc-cold\.skey|cc-hot\.skey|[a-z]+\.payment\.skey)$|/priv/wallet/.*\.skey$'

# The ONLY private keys allowed on a hot BP.
ALLOWED_REGEX='/priv/pool/[^/]+/(kes\.skey|hot\.skey|vrf\.skey)$'

audit_pod() {
    local ns="$1" want="${2:-}"
    local pod
    pod=$("$KUBECTL" get pods -n "$ns" -o name 2>/dev/null \
        | { [ -n "$want" ] && grep -i "$want" || cat; } | head -1)
    [ -z "$pod" ] && pod=$("$KUBECTL" get pods -n "$ns" -o name 2>/dev/null | head -1)
    if [ -z "$pod" ]; then
        echo -e "${RED}✗ no pod found in namespace '${ns}'${NC}"
        return 2
    fi
    pod="${pod#pod/}"
    echo -e "${BLUE}== ${ns}  (${pod}) ==${NC}"

    local listing
    listing=$("$KUBECTL" exec -n "$ns" "$pod" -- \
        sh -c "find ${PRIV_DIR} -type f -name '*.skey' -o -path '*cold.counter*' 2>/dev/null" 2>/dev/null) || {
        echo -e "${RED}✗ cannot exec into ${ns}/${pod}${NC}"; return 2; }

    local forbidden=0 allowed=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if echo "$f" | grep -Eq "$ALLOWED_REGEX"; then
            allowed=$((allowed+1))
            echo -e "  ${GREEN}ok   ${NC} $f"
        elif echo "$f" | grep -Eq "$FORBIDDEN_REGEX"; then
            forbidden=$((forbidden+1))
            echo -e "  ${RED}LEAK ${NC} $f"
        fi
    done <<< "$listing"

    if [ "$forbidden" -gt 0 ]; then
        echo -e "  ${RED}✗ ${forbidden} forbidden key(s) on hot host${NC} (${allowed} hot key(s) ok)"
        return 1
    fi
    echo -e "  ${GREEN}✓ clean — only hot keys present${NC} (${allowed})"
    return 0
}

rc=0
if [ -n "${NAMESPACES:-}" ]; then
    for ns in $NAMESPACES; do audit_pod "$ns" || rc=1; echo; done
elif [ -n "${1:-}" ]; then
    audit_pod "$1" "${2:-}" || rc=1
else
    echo "Usage: $0 <namespace> [pod-substring]   |   NAMESPACES='ns1 ns2' $0" >&2
    exit 64
fi

exit "$rc"
