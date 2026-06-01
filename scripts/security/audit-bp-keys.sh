#!/usr/bin/env bash
# audit-bp-keys.sh — Audit a block-producer pod for private keys that are not
#                    protected at rest.
#
# READ-ONLY. Makes no changes. Exits non-zero if any sensitive key is sitting in
# plaintext, so it can be wired into CI / a CronJob / Alertmanager.
#
# Two acceptable protection models for the offline-only keys
# (cold.skey, cold.counter, calidus.skey, and everything under priv/wallet/):
#   A) Air-gap   — keys live only on main6, NOT on the BP at all.
#   B) CNTools encryption at rest — keys live on the BP but GPG-symmetric
#      ("password") encrypted, i.e. present as <name>.skey.gpg with no plaintext.
#
# The HOT key set MUST stay plaintext (the node reads it at runtime):
#   priv/pool/<pool>/{kes|hot}.skey, vrf.skey
#
# Usage:
#   ./audit-bp-keys.sh <namespace> [pod-substring]
#   NAMESPACES="cmainnet-bp haiti-bp" ./audit-bp-keys.sh
#
# Env: PRIV_DIR (default /opt/cardano/cnode/priv), KUBECTL (default kubectl)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
PRIV_DIR="${PRIV_DIR:-/opt/cardano/cnode/priv}"
KUBECTL="${KUBECTL:-kubectl}"

# Hot keys that are allowed (in fact required) to be plaintext on the BP.
HOT_REGEX='/priv/pool/[^/]+/(kes\.skey|hot\.skey|vrf\.skey)$'

audit_pod() {
    local ns="$1" want="${2:-}"
    local pod
    pod=$("$KUBECTL" get pods -n "$ns" -o name 2>/dev/null \
        | { [ -n "$want" ] && grep -i "$want" || cat; } | head -1)
    [ -z "$pod" ] && pod=$("$KUBECTL" get pods -n "$ns" -o name 2>/dev/null | head -1)
    if [ -z "$pod" ]; then
        echo -e "${RED}x no pod found in namespace '${ns}'${NC}"; return 2
    fi
    pod="${pod#pod/}"
    echo -e "${BLUE}== ${ns}  (${pod}) ==${NC}"

    # All signing-key material (plaintext *.skey, encrypted *.skey.gpg, cold.counter*).
    local listing
    listing=$("$KUBECTL" exec -n "$ns" "$pod" -- sh -c \
        "find ${PRIV_DIR} -type f \( -name '*.skey' -o -name '*.skey.gpg' -o -path '*cold.counter*' \) 2>/dev/null" 2>/dev/null) || {
        echo -e "${RED}x cannot exec into ${ns}/${pod}${NC}"; return 2; }

    local plain=0 enc=0 hot=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        case "$f" in
            *.skey.gpg)
                enc=$((enc+1)); echo -e "  ${GREEN}enc  ${NC} $f" ;;
            *)
                if echo "$f" | grep -Eq "$HOT_REGEX"; then
                    hot=$((hot+1)); echo -e "  ${GREEN}hot  ${NC} $f (must stay plaintext)"
                else
                    plain=$((plain+1)); echo -e "  ${RED}PLAIN${NC} $f"
                fi ;;
        esac
    done <<< "$listing"

    if [ "$plain" -gt 0 ]; then
        echo -e "  ${RED}x ${plain} sensitive key(s) in PLAINTEXT${NC} - encrypt (CNTools) or air-gap. (${enc} encrypted, ${hot} hot)"
        return 1
    fi
    echo -e "  ${GREEN}OK no plaintext sensitive keys${NC} (${enc} encrypted at rest, ${hot} hot)"
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
