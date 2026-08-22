#!/usr/bin/env bash
# The daemon fallback's integrity pin must move with its version (HR015 #583)
# ==========================================================================
#
# THE DEFECT. install.sh retries once against ASSISTANT_FALLBACK_VERSION when
# the primary download fails. `_ostler_assistant_set_urls` re-pointed the URLs
# and left ASSISTANT_TARBALL_SHA256 alone, so the fallback tarball was checked
# against the PRIMARY's digest, mismatched, and the install aborted with
#
#     ostler-assistant tarball failed the cross-origin integrity pin
#
# That is the branch taken by someone whose primary download has ALREADY
# failed. They were told their download looked tampered with, at the worst
# possible moment, for a reason that was ours. The rescue path never rescued
# anyone.
#
# WHY THIS TEST IS BEHAVIOURAL. The fix could be faked by declaring a second
# constant and never using it -- which is precisely the shape of the original
# bug, a value that exists and is not applied. So this EXTRACTS the real
# function and CALLS it.
#
# ASSERTED
#   1. asking for the primary version selects the primary digest
#   2. asking for the fallback version selects the fallback digest  <- the fix
#   3. the two digests actually differ (anti-vacuity: if they were equal the
#      test above would pass no matter what the function did)
#   4. both baked pins match their PUBLISHED .sha256 sidecars, so a version
#      bumped without its checksum is caught here rather than on a customer's
#      machine. Network; reports CANNOT-RUN rather than passing if unreachable.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$*"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$*" >&2; FAIL=$((FAIL+1)); }

printf 'test_fallback_pin_moves_with_the_version\n'
[ -f "$INSTALL_SH" ] || { bad "premise: install.sh not found"; exit 1; }

val() { sed -nE "s/^$1=\"([^\"]*)\".*/\\1/p" "$INSTALL_SH" | head -1; }
PRIMARY_V="$(sed -nE 's/^OSTLER_ASSISTANT_VERSION="\$\{OSTLER_ASSISTANT_VERSION:-([^}"]+)\}".*/\1/p' "$INSTALL_SH" | head -1)"
FALLBACK_V="$(val ASSISTANT_FALLBACK_VERSION)"
PRIMARY_SHA="$(val DEFAULT_ASSISTANT_TARBALL_SHA256)"
FALLBACK_SHA="$(val DEFAULT_ASSISTANT_FALLBACK_TARBALL_SHA256)"
REPO="$(sed -nE 's/^OSTLER_ASSISTANT_REPO="\$\{OSTLER_ASSISTANT_REPO:-([^}"]+)\}".*/\1/p' "$INSTALL_SH" | head -1)"
TARGET="$(sed -nE 's/^OSTLER_ASSISTANT_TARGET="\$\{OSTLER_ASSISTANT_TARGET:-([^}"]+)\}".*/\1/p' "$INSTALL_SH" | head -1)"

for pair in "PRIMARY_V:$PRIMARY_V" "FALLBACK_V:$FALLBACK_V" "PRIMARY_SHA:$PRIMARY_SHA" \
            "FALLBACK_SHA:$FALLBACK_SHA" "REPO:$REPO" "TARGET:$TARGET"; do
    if [ -z "${pair#*:}" ]; then
        bad "premise: could not parse ${pair%%:*} out of install.sh; every check below would be vacuous"
        exit 1
    fi
done
ok "parsed both versions and both digests (primary v${PRIMARY_V}, fallback v${FALLBACK_V})"

# --- 3. anti-vacuity, run FIRST because everything else leans on it ---------
if [ "$PRIMARY_SHA" = "$FALLBACK_SHA" ]; then
    bad "the two digests are IDENTICAL, so checks 1 and 2 cannot distinguish anything"
    exit 1
fi
ok "the two digests differ, so selecting between them is observable"

# --- extract + call the real function ---------------------------------------
FN="$(awk '/^_ostler_assistant_set_urls\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$INSTALL_SH")"
LINES="$(printf '%s\n' "$FN" | grep -c .)"
if [ "${LINES:-0}" -lt 8 ]; then
    bad "premise: extracted only ${LINES} lines of _ostler_assistant_set_urls"
    exit 1
fi
ok "extracted the real function (${LINES} lines)"

# Ask the function which digest it selects for a given version.
sha_for() {
    (
        OSTLER_ASSISTANT_TARGET="$TARGET"
        OSTLER_ASSISTANT_REPO="$REPO"
        ASSISTANT_FALLBACK_VERSION="$FALLBACK_V"
        DEFAULT_ASSISTANT_TARBALL_SHA256="$PRIMARY_SHA"
        ASSISTANT_FALLBACK_TARBALL_SHA256="$FALLBACK_SHA"
        ASSISTANT_TARBALL_SHA256=""
        eval "$FN"
        _ostler_assistant_set_urls "$1"
        printf '%s' "$ASSISTANT_TARBALL_SHA256"
    )
}

# --- 1 + 2 ------------------------------------------------------------------
GOT="$(sha_for "$PRIMARY_V")"
if [ "$GOT" = "$PRIMARY_SHA" ]; then
    ok "v${PRIMARY_V} (primary) selects the primary digest"
else
    bad "v${PRIMARY_V} selected ${GOT:-<empty>}, expected the primary digest"
fi

GOT="$(sha_for "$FALLBACK_V")"
if [ "$GOT" = "$FALLBACK_SHA" ]; then
    ok "v${FALLBACK_V} (fallback) selects the FALLBACK digest -- this is #583"
else
    bad "v${FALLBACK_V} selected ${GOT:-<empty>}, expected the fallback digest. \
The rescue path is checking the fallback tarball against the primary's pin and will abort."
fi

# --- 4. both pins match their published sidecars ----------------------------
sidecar() {
    env -u GH_TOKEN -u GITHUB_TOKEN -u HTTPS_PROXY -u https_proxy -u ALL_PROXY \
        curl -fsSL --noproxy '*' --max-time 30 \
        "https://github.com/${REPO}/releases/download/hub-v$1/ostler-assistant-${TARGET}-v$1.tar.gz.sha256" 2>/dev/null \
        | awk '{print $1}' | head -1
}
NET_OK=1
for spec in "${PRIMARY_V}:${PRIMARY_SHA}:primary" "${FALLBACK_V}:${FALLBACK_SHA}:fallback"; do
    v="${spec%%:*}"; rest="${spec#*:}"; want="${rest%%:*}"; label="${rest#*:}"
    pub="$(sidecar "$v")"
    if [ -z "$pub" ]; then
        printf '  CANNOT-RUN: could not fetch the %s sidecar for v%s. NOT a pass.\n' "$label" "$v" >&2
        NET_OK=0
        continue
    fi
    if [ "$pub" = "$want" ]; then
        ok "the ${label} pin matches the published hub-v${v} sidecar"
    else
        bad "the ${label} pin does NOT match hub-v${v}: baked ${want}, published ${pub}"
    fi
done

printf '\n  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
[ "$NET_OK" -eq 1 ] || exit 2
printf 'FALLBACK PIN MOVES WITH THE VERSION\n'
