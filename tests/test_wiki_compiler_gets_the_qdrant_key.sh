#!/usr/bin/env bash
#
# test_wiki_compiler_gets_the_qdrant_key.sh
#
# #550 -- THE WIKI COMPILER IS A CONTAINER, AND THE SHIM CANNOT REACH IT.
#
# #1222 flipped OSTLER_STORE_AUTH_ENFORCE to default-ON, so qdrant boots with
# QDRANT__SERVICE__API_KEY set and 401s any uncredentialled read. Every
# host-side Python client is covered by the store-auth .pth shim. The
# wiki-compiler is not, by TWO independent locks:
#
#   1. the .pth is written into venv site-packages -- never into a pinned image
#   2. lib/ostler_store_auth.py's allow-list is loopback-only, so it would not
#      fire for the compose hostname `qdrant` even if it were baked in
#
# So the credential has to arrive as an environment variable on the service.
#
# ⚠️ WHY THIS DESERVES A GATE AND NOT JUST A LINE. The failure is SILENT.
# CM044's load_conversations raises and renders a section-failure stub, but the
# people, preference and browsing loaders fall back to empty and render
# SUCCESSFULLY. The wiki comes out THIN -- People and Topics quietly short --
# which is indistinguishable from a customer who simply has little data. A
# healthy, fully populated graph reads as an empty one, and the next person to
# see it will file an ingest defect and chase the wrong chain.
#
# 🔴 AND THE SECOND HALF IS PER-STORE BINDING. On 2026-08-28 the installer
# presented the OXIGRAPH bearer to QDRANT, got 401, read that 401 as a
# credential leak and aborted every install with ERR-06-STORE-AUTH-LEAK. It is
# not enough for a credential to be present SOMEWHERE. This gate asserts the
# Qdrant key is in the compiler's block AND that no Oxigraph secret is.
#
# The service block is bounded by COMPUTATION, not by a hardcoded line range:
# ranges rot, and an unterminated one silently swallows the rest of the file and
# makes every assertion below vacuous. The terminator is asserted.
#
# Assertions use `grep -c` and NEVER `... | grep -q`: under pipefail a piped
# `grep -q` exits on first match, SIGPIPEs the producer, and the pipeline
# reports FAILURE for a needle that IS present.
#
# British English throughout.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"

fails=0
pass() { echo "ok: $1"; }
fail() { echo "FAIL: $1" >&2; fails=$((fails + 1)); }

[ -f "${INSTALL_SH}" ] || { echo "FAIL: install.sh not found -- CANNOT-RUN" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────────────
# Bound the wiki-compiler service block. Start = its own key; end = the next
# top-level service key at the same indent. Both are asserted.
# ─────────────────────────────────────────────────────────────────────
block_of() {   # $1 = file, $2 = service name -> prints "start end", or empty
    local f="$1" svc="$2" s e
    s="$(/usr/bin/grep -nE "^  ${svc}:\$" "${f}" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
    [ -n "${s}" ] || return 1
    e="$(/usr/bin/awk -v s="${s}" 'NR>s && /^  [a-z][a-z0-9_-]*:$/ {print NR-1; exit}' "${f}")"
    [ -n "${e}" ] || return 1
    printf '%s %s\n' "${s}" "${e}"
}

RANGE="$(block_of "${INSTALL_SH}" 'wiki-compiler')" || {
    echo "FAIL: CANNOT-RUN -- could not bound the wiki-compiler service block. The" >&2
    echo "      anchors moved; re-point this gate rather than deleting it." >&2
    exit 1
}
WC_START="${RANGE% *}"; WC_END="${RANGE#* }"
BLOCK="$(/usr/bin/sed -n "${WC_START},${WC_END}p" "${INSTALL_SH}")"
echo "wiki-compiler block: lines ${WC_START}..${WC_END} ($(printf '%s' "${BLOCK}" | /usr/bin/wc -l | /usr/bin/tr -d ' ') lines)"

n_key="$(printf '%s' "${BLOCK}" | /usr/bin/grep -cE '^\s+- QDRANT_API_KEY=' || true)"
n_url="$(printf '%s' "${BLOCK}" | /usr/bin/grep -cE '^\s+- QDRANT_URL=' || true)"

# ── ARM 1: the credential is there ───────────────────────────────────
if [ "${n_key}" -ge 1 ]; then
    pass "arm1: the wiki-compiler service carries QDRANT_API_KEY"
else
    fail "arm1: the wiki-compiler service has NO QDRANT_API_KEY. Under the post-#1222 default, every Qdrant read from the compiler 401s and the wiki renders THIN -- People and Topics short, with no error surfaced to the customer"
fi

# ── ARM 2: CONTROL. Must be non-zero, or arm 1's zero means nothing ──
if [ "${n_url}" -ge 1 ]; then
    pass "arm2: CONTROL -- QDRANT_URL is present in the same bounded block (${n_url}), so the bounds are right and a zero above would be a real absence"
else
    fail "arm2: CANNOT-RUN -- QDRANT_URL not found inside the computed block, so the block bounds are wrong and every other arm here is vacuous"
fi

# ── ARM 3: PER-STORE. No Oxigraph secret in the compiler's env ───────
n_oxi_secret="$(printf '%s' "${BLOCK}" | /usr/bin/grep -cE 'OXIGRAPH_TOKEN|OXIGRAPH_API_KEY|Authorization' || true)"
if [ "${n_oxi_secret}" = "0" ]; then
    pass "arm3: no Oxigraph credential in the compiler's environment (per-store binding holds)"
else
    fail "arm3: an Oxigraph secret has appeared in the wiki-compiler env (${n_oxi_secret}). Oxigraph 0.4.6 has no native auth and compose peers reach it directly; handing this container that secret is the ERR-06 shape -- the wrong credential at the wrong store"
fi

# ── ARM 4: the store side still has its own key ──────────────────────
n_service_key="$(/usr/bin/grep -cE '^\s+QDRANT__SERVICE__API_KEY:' "${INSTALL_SH}" || true)"
if [ "${n_service_key}" -ge 1 ]; then
    pass "arm4: the qdrant service still declares QDRANT__SERVICE__API_KEY (the store half is untouched)"
else
    fail "arm4: QDRANT__SERVICE__API_KEY has vanished from the qdrant service -- passing a key to a store that no longer wants one is a different defect, not a fix"
fi

# ── ARM 5: MUTATION. Remove the line; arm 1 must go RED ──────────────
#
# A gate that cannot fail proves nothing. The delta is ASSERTED before the
# mutant is read -- a mutation that did not mutate is CANNOT-RUN, not a pass.
MUT="$(mktemp "${TMPDIR:-/tmp}/wikicred-mut.XXXXXX")"
/usr/bin/sed '/^[[:space:]]*- QDRANT_API_KEY=/d' "${INSTALL_SH}" > "${MUT}"
before="$(/usr/bin/grep -cE '^\s+- QDRANT_API_KEY=' "${INSTALL_SH}" || true)"
after="$(/usr/bin/grep -cE '^\s+- QDRANT_API_KEY=' "${MUT}" || true)"
if [ "$(( before - after ))" -lt 1 ]; then
    fail "arm5: CANNOT-RUN -- the mutation removed ${before}->${after} lines, i.e. it did not mutate. A mutation test that did not mutate proves nothing"
else
    MRANGE="$(block_of "${MUT}" 'wiki-compiler')" || MRANGE=""
    if [ -z "${MRANGE}" ]; then
        fail "arm5: CANNOT-RUN -- could not bound the block in the mutant"
    else
        m_s="${MRANGE% *}"; m_e="${MRANGE#* }"
        m_key="$(/usr/bin/sed -n "${m_s},${m_e}p" "${MUT}" | /usr/bin/grep -cE '^\s+- QDRANT_API_KEY=' || true)"
        if [ "${m_key}" = "0" ]; then
            pass "arm5: MUTATION RED -- removing the line yields 0 in the block, which arm1 fails on (${before} -> ${after} lines removed file-wide)"
        else
            fail "arm5: mutation left ${m_key} in the block -- arm1 is not actually guarding this line"
        fi
    fi
fi
/bin/rm -f "${MUT}"

echo
if [ "${fails}" -eq 0 ]; then
    echo "GATE OK: the wiki compiler is given Qdrant's credential, and only Qdrant's."
    exit 0
fi
echo "GATE FAILED: ${fails} assertion(s)." >&2
exit 1
