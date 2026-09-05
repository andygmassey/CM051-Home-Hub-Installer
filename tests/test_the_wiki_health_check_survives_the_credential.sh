#!/usr/bin/env bash
# CM051 #1594 follow-on -- the wiki health check must survive its own credential.
#
# THE DEFECT THIS GUARDS, and it was self-inflicted. #1594 put :8044 behind
# auth_basic. The installer's readiness poll used:
#
#     curl -sf -o /dev/null -m 3 "http://127.0.0.1:8044/"
#
# `-f` fails on any 4xx. MEASURED against a real 401 from the pinned nginx:
# rc=22. So a CORRECTLY PROTECTED wiki reads as a dead one, and the
# consequences are not cosmetic:
#
#   * 30 polls x 2s burned on every install
#   * WIKI_PORT_UP=false -> WIKI_FIRST_COMPILE_OK=false, HEALTHY=false
#   * a warning that the wiki is not answering, which is FALSE
#   * and the completion banner is gated on WIKI_FIRST_COMPILE_OK, so the
#     customer is never shown "Your wiki:" NOR the password line -- the fix
#     would have hidden its own credential
#
# THE INSTRUMENT MUST SHARE A SURFACE WITH THE CLAIM. The line this gates says
# "your wiki is at this URL", so the evidence must be that the customer can GET
# it: authenticate, and require 200.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${REPO}/install.sh"

PASS=0; FAIL=0; CANT=0
ok()   { printf '  [PASS] %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  [FAIL] %s\n' "$*"; FAIL=$((FAIL+1)); }
cant() { printf '  [CANNOT-RUN] %s\n' "$*"; CANT=$((CANT+1)); }

[ -r "$INSTALL_SH" ] || { cant "install.sh unreadable"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }
_lines="$(wc -l < "$INSTALL_SH" | tr -d ' ')"
[ "${_lines}" -ge 20000 ] || { cant "install.sh is only ${_lines} lines; refusing a truncated subject"; echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2; }

# The readiness poll: the curl that decides WIKI_PORT_UP.
poll_block() {
    awk '/WIKI_PORT_UP=false/{f=1} f{print} f && /^        done$/{exit}' "$1"
}
BLOCK="$(poll_block "$INSTALL_SH")"
_bl="$(printf '%s\n' "$BLOCK" | wc -l | tr -d ' ')"
if [ "${_bl}" -lt 5 ]; then
    cant "extracted only ${_bl} line(s) of the readiness poll; the anchors moved and this test measures nothing"
    echo "== 0 pass / 0 fail / 1 cannot-run =="; exit 2
fi
ok "located the readiness poll (${_bl} lines)"

# ARM 1 -- THE DEFECT. -f must not be used against the credentialed port.
if printf '%s\n' "$BLOCK" | grep -qE 'curl[^|]*-[A-Za-z]*f[A-Za-z]* '; then
    bad "the readiness poll still uses curl -f, which fails on the 401 a protected wiki returns"
else
    ok "the readiness poll does not use curl -f"
fi

# ARM 2 -- it authenticates.
if printf '%s\n' "$BLOCK" | grep -q 'WIKI_PASSWORD'; then
    ok "the readiness poll authenticates with the generated password"
else
    bad "the readiness poll does not send the credential, so it cannot prove the customer can read the wiki"
fi

# ARM 3 -- it requires 200 specifically, not merely 'some response'.
if printf '%s\n' "$BLOCK" | grep -q '"200"'; then
    ok "the readiness poll requires HTTP 200"
else
    bad "the readiness poll does not require 200; a 401 or 503 would read as ready"
fi

# ARM 4 -- loopback is not routed through a customer's proxy.
if printf '%s\n' "$BLOCK" | grep -q 'noproxy'; then
    ok "the readiness poll bypasses any configured HTTP proxy"
else
    bad "the readiness poll can be answered by a customer's HTTP proxy instead of the wiki"
fi

# ARM 5 -- MUST-MISS. Arms 1-4 must be capable of failing. Re-run arm 1's
# predicate against the exact line the defect shipped as; if that does not
# match, arm 1 is unfalsifiable and its pass above means nothing.
_shipped='            if curl -sf -o /dev/null -m 3 "http://127.0.0.1:8044/" 2>/dev/null; then'
if printf '%s\n' "$_shipped" | grep -qE 'curl[^|]*-[A-Za-z]*f[A-Za-z]* '; then
    ok "must-miss: arm 1's predicate DOES match the line the defect shipped as"
else
    bad "must-miss: arm 1's predicate does not match the shipped defect, so arm 1 proves nothing"
fi

# ARM 6 -- the failure path says WHICH failure. 000 (nothing answered) and 401
# (answered, refused us) are different repairs.
if grep -q 'MSG_INFO_WIKI_PORT_LAST_STATUS' "$INSTALL_SH"; then
    ok "a failed poll reports the last HTTP status, so 000 and 401 are tellable apart"
else
    bad "a failed poll reports no status, so 'nothing there' and 'refused us' look identical"
fi

echo "== ${PASS} pass / ${FAIL} fail / ${CANT} cannot-run =="
[ "${FAIL}" -gt 0 ] && exit 1
[ "${CANT}" -gt 0 ] && exit 2
exit 0
