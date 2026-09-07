#!/usr/bin/env bash
# Regression test for #1754: the Ollama LaunchAgent check must not abort the
# install when the agent is registered but has not yet reached
# `state = running`.
#
# ROOT CAUSE (measured on two consecutive box walks of v1.0.73, archie
# account, Mac mini, 2026-09-07):
#   install.sh runs `set -Eeuo pipefail` with an abort-on-error ERR trap.
#   The pre-fix line was a BARE simple command:
#
#       _ollama_agent_is_running; [[ $? -eq 2 ]] && _ollama_domain_absent=1
#
#   `_ollama_agent_is_running` returns 1 for a state this code expects --
#   registered but not yet running -- and a bare non-zero return trips
#   errexit. The install died there, and the 90-second poll below it, which
#   exists to absorb precisely that window, never ran a single iteration.
#   Both walks recorded elapsed_s=0.
#
# WHY THE ORIGINAL LOOKED LIKE A PORT BUG: the first walk also had a stale
# LaunchAgent holding 11434, so `ollama.err` was full of `address already in
# use`. Clearing the port changed nothing -- the second walk started Ollama
# cleanly (HTTP 200, `state = running`) and aborted at the same line. The
# port was a co-occurring condition, not the cause.
#
# WHY THE LINE NUMBER MISLED: the ERR trap reports $LINENO, which resolves to
# the enclosing `fi`, so the abort surfaced as L12423 while the defect was at
# L12399.
#
# The RED control below reintroduces the exact pre-fix line and asserts this
# test FAILS on it. Without that, a test that only exercises the fixed code
# cannot tell you it would have caught the bug.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_SH="${SCRIPT_DIR}/../install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[[ -f "${INSTALL_SH}" ]] || { printf 'FAIL: install.sh not found\n' >&2; exit 1; }

# ── Extract the SHIPPED block, so this test tracks the real code ─────────
BLOCK="$(awk '
    /^    _ollama_domain_absent=0$/                                { grab=1 }
    grab                                                           { print }
    grab && /^    if \[\[ \$_ollama_rc -eq 2 \]\]; then/           { exit }
' "${INSTALL_SH}")"

printf '%s\n' "${BLOCK}" | grep -qF '_ollama_agent_is_running || _ollama_rc=$?' || {
    printf 'FAIL: could not extract the fixed block from install.sh\n' >&2
    printf '      (has the guarded call at :12399 been reverted or moved?)\n' >&2
    exit 1
}

# The pre-fix construct, verbatim, for the RED control.
RED_BLOCK='    _ollama_domain_absent=0
    _ollama_agent_is_running; [[ $? -eq 2 ]] && _ollama_domain_absent=1'

# ── Harness: run a block with a stubbed agent check, report survival ─────
# Emits "SURVIVED <absent>" or "ABORTED", under the same shell options and an
# aborting ERR trap, matching install.sh.
run_block() {
    local block="$1" stub_rc="$2"
    cat > "${WORK}/case.sh" <<EOF
set -Eeuo pipefail
trap 'echo ABORTED; exit 99' ERR
_ollama_agent_is_running() { return ${stub_rc}; }
${block}
echo "SURVIVED \${_ollama_domain_absent}"
EOF
    bash "${WORK}/case.sh" 2>/dev/null || true
}

fails=0
check() {
    local label="$1" got="$2" want="$3"
    if [[ "${got}" == "${want}" ]]; then
        printf 'ok   %s -- %s\n' "${label}" "${got}"
    else
        printf 'FAIL %s -- got %-20s want %s\n' "${label}" "${got}" "${want}" >&2
        fails=$((fails + 1))
    fi
}

printf '== fixed block ==\n'
# rc=1 IS THE ORIGINAL ABORTING INPUT: registered, not yet running.
check "rc=1 registered-not-yet-running survives" "$(run_block "${BLOCK}" 1)" "SURVIVED 0"
check "rc=0 running survives"                    "$(run_block "${BLOCK}" 0)" "SURVIVED 0"
check "rc=2 no-gui-domain sets absent"           "$(run_block "${BLOCK}" 2)" "SURVIVED 1"

printf '== RED control (pre-fix line must abort on rc=1) ==\n'
check "pre-fix rc=1 aborts"    "$(run_block "${RED_BLOCK}" 1)" "ABORTED"
# The pre-fix line was not broken for every rc -- only a non-zero return trips
# errexit. Recording that asymmetry is what makes the RED control specific
# rather than a blanket "old code bad".
check "pre-fix rc=0 survived"  "$(run_block "${RED_BLOCK}" 0)" "SURVIVED 0"
check "pre-fix rc=2 aborts"    "$(run_block "${RED_BLOCK}" 2)" "ABORTED"

if [[ ${fails} -ne 0 ]]; then
    printf '\n%d assertion(s) failed\n' "${fails}" >&2
    exit 1
fi
printf '\nall assertions passed\n'
