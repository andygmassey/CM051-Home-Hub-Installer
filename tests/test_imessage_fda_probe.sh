#!/usr/bin/env bash
#
# tests/test_imessage_fda_probe.sh
#
# Locks the contract between install.sh's CX-60 iMessage FDA probe
# and:
#   1. The Doctor rule check_imessage_fda (vendor/doctor/agent/
#      diagnostic_rules.py).
#   2. The writer at lib/write_pipeline_signals.py.
#   3. The customer-string catalogue at install.sh.strings.en-GB.sh.
#
# The probe is best-effort (must NOT kill the install). The Doctor
# rule must:
#   - Stay quiet when the install never wrote the flag (legacy).
#   - Stay quiet when the install wrote needed=false.
#   - Render the card when the install wrote needed=true AND a live
#     chat.db re-probe fails.
#   - Auto-dismiss when the live re-probe succeeds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
RULES_DIR="${REPO_ROOT}/vendor/doctor/agent"

# ── Case 1: install.sh has the CX-60 probe block ────────────────
if ! grep -q "3.14e-probe iMessage FDA probe (CX-60)" "$INSTALL_SH"; then
    echo "FAIL [case-1]: CX-60 probe block missing from install.sh" >&2
    exit 1
fi
echo "PASS [case-1]: CX-60 probe block present in install.sh"

# ── Case 2: probe block is best-effort (set +e / set -e wrap) ───
# Extract the block and verify it both sets +e (probe is best-
# effort) and restores set -e (no leaking into the rest of install).
BLOCK=$(awk '
    /3.14e-probe iMessage FDA probe \(CX-60\)/ { in_block=1 }
    in_block && /end Apple Silicon guard/ { exit }
    in_block { print }
' "$INSTALL_SH")
if [[ -z "$BLOCK" ]]; then
    echo "FAIL [case-2]: could not extract CX-60 probe block" >&2
    exit 1
fi
if ! printf '%s\n' "$BLOCK" | grep -q "set +e"; then
    echo "FAIL [case-2]: probe block missing 'set +e' best-effort guard" >&2
    exit 1
fi
if ! printf '%s\n' "$BLOCK" | grep -q "set -e"; then
    echo "FAIL [case-2]: probe block missing 'set -e' restore" >&2
    exit 1
fi
echo "PASS [case-2]: probe block is best-effort (set +e / set -e wrap)"

# ── Case 3: writer invocation passes --imessage-fda-needed ──────
if ! printf '%s\n' "$BLOCK" | grep -q "imessage-fda-needed"; then
    echo "FAIL [case-3]: probe block does not call writer with --imessage-fda-needed" >&2
    exit 1
fi
echo "PASS [case-3]: probe writes via --imessage-fda-needed flag"

# ── Case 4: catalogue carries the probe strings ─────────────────
for key in MSG_INFO_IMESSAGE_FDA_PROBE_BEGIN \
           MSG_INFO_IMESSAGE_FDA_PROBE_GRANTED \
           MSG_INFO_IMESSAGE_FDA_PROBE_NEEDS_GRANT \
           MSG_INFO_IMESSAGE_FDA_PROBE_SKIPPED_NO_DAEMON \
           MSG_WARN_IMESSAGE_FDA_PROBE_SIGNAL_WRITE_FAILED; do
    if ! grep -q "^${key}=" "$STRINGS_FILE"; then
        echo "FAIL [case-4]: catalogue missing $key" >&2
        exit 1
    fi
done
echo "PASS [case-4]: all 5 CX-60 catalogue strings present"

# ── Case 5: Doctor rule renders the card from synthetic state ───
python3 - <<PY
import sys, types
# Stub httpx (heavy network dep we don't need for the unit-shape test).
httpx_stub = types.ModuleType("httpx")
class _Err(Exception): pass
class _C:
    def __init__(self, *a, **kw): pass
    def get(self, url): raise _Err("stub")
httpx_stub.Client = _C
httpx_stub.RequestError = _Err
sys.modules["httpx"] = httpx_stub

sys.path.insert(0, "${RULES_DIR}")
import diagnostic_rules as dr

# Stay-quiet paths
class _Empty: pipeline_signals = None
assert dr.check_imessage_fda(_Empty()) == []

class _Sig:
    imessage_chat_db_fda_needed = None
class _SnapNone:
    pipeline_signals = _Sig()
assert dr.check_imessage_fda(_SnapNone()) == []

class _SigFalse:
    imessage_chat_db_fda_needed = False
class _SnapFalse:
    pipeline_signals = _SigFalse()
assert dr.check_imessage_fda(_SnapFalse()) == []

# Card rendered when needed=True + live probe fails
class _SigTrue:
    imessage_chat_db_fda_needed = True
class _SnapTrue:
    pipeline_signals = _SigTrue()
dr._imessage_chat_db_readable = lambda: False
findings = dr.check_imessage_fda(_SnapTrue())
assert len(findings) == 1, findings
f = findings[0]
assert f["severity"] == "warning"
assert "Full Disk Access" in f["title"]
assert "x-apple.systempreferences" in f["fix_command"]
assert "launchctl kickstart" in f["detail"]
assert f["category"] == "installation"

# Auto-dismiss when live probe succeeds
dr._imessage_chat_db_readable = lambda: True
assert dr.check_imessage_fda(_SnapTrue()) == []

# Rule registered in ALL_RULES
assert any(r.__name__ == "check_imessage_fda" for r in dr.ALL_RULES)
print("PASS [case-5]: Doctor rule passes all 5 sub-assertions")
PY

echo ""
echo "ALL CX-60 IMESSAGE FDA PROBE TESTS PASSED"
