#!/usr/bin/env bash
# The region-persistence step must not print a raw Python traceback to the
# customer's screen (#622 / v1061-D001).
#
# THE DEFECT, off the v1.0.61 walk: during the encrypt_db step the best-effort
# region write runs `"$OSTLER_PYTHON" - ... <<'PY' || warn` with NO stderr
# capture, so when `ostler_security.region.save_region` raises, the raw
# traceback lands on the customer's terminal and the step still reports ok.
# The sibling consent-cli call five lines below already captures stderr and
# surfaces it cleanly; this is the un-migrated one. status=ok is correct
# (region persistence is best-effort by design); the defect is the LEAK.
#
# This drives the REAL region construct extracted from install.sh against a
# stub `ostler_security.region` that raises, and asserts the traceback does
# NOT reach the customer-visible output. Behavioural, on unmodified source
# (the #619 bar): RED before the fix (a real Traceback leaks), GREEN after.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${OSTLER_TEST_INSTALL_SH:-${REPO_ROOT}/install.sh}"
FAIL=0
ok()  { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; FAIL=1; }

[ -f "$INSTALL_SH" ] || { echo "CANNOT-RUN: install.sh not at $INSTALL_SH (exit 2)" >&2; exit 2; }
command -v python3 >/dev/null || { echo "CANNOT-RUN: no python3 (exit 2)" >&2; exit 2; }

# Extract the region-persistence construct: from "# Region first." up to (not
# including) the consent-cli section that follows it. Captures the whole block
# whether it is the pre-fix `|| warn` or the post-fix captured form.
REGION_BLOCK="$(awk '/# Region first\./{f=1} f && /Wraps .*consent_cli/{exit} f{print}' "$INSTALL_SH")"
if [ -z "$REGION_BLOCK" ]; then
    echo "CANNOT-RUN: could not extract the region block from install.sh; anchors moved (exit 2)" >&2
    exit 2
fi
if ! grep -q 'ostler_security.region' <<<"$REGION_BLOCK"; then
    echo "CANNOT-RUN: extracted block does not invoke ostler_security.region; wrong region (exit 2)" >&2
    exit 2
fi

# $1 = "fail" (save_region raises) or "ok" (save_region succeeds). Echoes the
# customer-visible output (stdout+stderr merged, as a terminal would show it).
_run_block() {
    local mode="$1" stub out
    stub="$(mktemp -d)"
    mkdir -p "$stub/ostler_security"
    : > "$stub/ostler_security/__init__.py"
    {
        printf 'class RegionResult:\n    def __init__(self, **kw):\n        pass\n'
        printf 'def save_region(result):\n'
        if [ "$mode" = fail ]; then
            printf '    raise RuntimeError("REGION_STUB_FAILURE_622")\n'
        else
            printf '    return None\n'
        fi
    } > "$stub/ostler_security/region.py"
    out="$(
        export OSTLER_PYTHON=python3 PYTHONPATH="$stub" \
               OSTLER_REGION=GB OSTLER_REGION_ISO=GB OSTLER_REGION_SOURCE=test \
               OSTLER_DIR="$stub/ostler" \
               MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING="Could not persist region.json (continuing)"
        warn() { printf 'WARN: %s\n' "$*"; }
        # cd into the stub so its ostler_security shadows any real one on
        # sys.path[0] (CWD), which would otherwise be imported first and
        # drag in the real crypto deps -- the harness must test the STUB.
        cd "$stub" || exit 1
        eval "$REGION_BLOCK" 2>&1
    )"
    rm -rf "$stub"
    printf '%s' "$out"
}

FAIL_OUT="$(_run_block fail)"
OK_OUT="$(_run_block ok)"

# ── ARM 1 (the defect): a failing region write must NOT leak a raw traceback ──
if grep -q 'Traceback (most recent call last)' <<<"$FAIL_OUT"; then
    bad "ARM 1 a raw Python traceback reaches the customer on region-write failure:"
    grep -nE 'Traceback|RuntimeError' <<<"$FAIL_OUT" | sed 's/^/         /' >&2
else
    ok "ARM 1 no raw traceback on region-write failure -- stderr is captured"
fi

# ── ARM 2 (positive control): the failure IS still surfaced, cleanly ──
if grep -q 'WARN:' <<<"$FAIL_OUT"; then
    ok "ARM 2 the failure is still surfaced as a clean warn, not silently swallowed"
else
    bad "ARM 2 the region failure produced no warn -- a captured stderr must not mean a swallowed failure."
fi

# ── ARM 3 (discrimination): a SUCCESSFUL region write leaks nothing either ──
if grep -q 'Traceback (most recent call last)' <<<"$OK_OUT"; then
    bad "ARM 3 a successful region write printed a traceback -- the harness is not discriminating."
else
    ok "ARM 3 a successful region write is clean -- the leak is failure-specific"
fi

if [ "$FAIL" -ne 0 ]; then
    echo "" >&2; echo "RESULT: FAIL -- the region step leaks a raw traceback to the customer." >&2
    exit 1
fi
echo "RESULT: PASS -- region-write failure surfaces as a clean warn, no raw traceback."
