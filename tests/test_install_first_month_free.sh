#!/usr/bin/env bash
#
# tests/test_install_first_month_free.sh
#
# Locks the install.sh G2 included-Pro activation block. This test
# verifies the post-licence-verification subscription activation that
# wires every fresh Hub install to 180 days (founding) of Ostler Pro per the G0
# subscription_gate contract (CM051 PR #190).
#
# Why this test exists:
#   - The activation is the customer's only path to the included window
#     of Pro. A regression silently breaks the trial without any obvious
#     symptom -- the Hub installs cleanly, the customer never knows.
#   - The non-fatal posture (warn-only on failure) must hold so a broken
#     subscription_gate.py never blocks a legitimate install.
#
# Verified scenarios:
#   1. activate_included_pro() writes a JSON state file when called
#      with a synthetic OSTLER_SUBSCRIPTION_STATE override.
#   2. The state has status=active, source=first_month_free, and an
#      expires_at ~180 days in the future.
#   3. install.sh contains the activation block + the 4 G2 MSG_* keys
#      are present in the en-GB strings catalogue.
#   4. install.sh structural sanity (still parses with bash -n).
#
# Synthetic fixtures only -- no real customer state files touched.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SCRIPT="${REPO_ROOT}/install.sh"
STRINGS_FILE="${REPO_ROOT}/install.sh.strings.en-GB.sh"
GATE_MODULE="${REPO_ROOT}/vendor/cm041/assistant_api/subscription_gate.py"

if [[ ! -f "$INSTALL_SCRIPT" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SCRIPT" >&2
    exit 1
fi
if [[ ! -f "$STRINGS_FILE" ]]; then
    echo "FAIL: strings file not found at $STRINGS_FILE" >&2
    exit 1
fi
if [[ ! -f "$GATE_MODULE" ]]; then
    echo "FAIL: subscription_gate.py not vendored at $GATE_MODULE" >&2
    exit 1
fi

# ── Parse check ──────────────────────────────────────────────────
if ! bash -n "$INSTALL_SCRIPT"; then
    echo "FAIL: install.sh fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: install.sh parses"

if ! bash -n "$STRINGS_FILE"; then
    echo "FAIL: strings file fails bash -n parse check" >&2
    exit 1
fi
echo "PASS: strings file parses"

# ── Structural sanity: activation block present ─────────────────
if ! grep -q 'Included-months subscription activation (G2)' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: G2 activation section header not found in install.sh" >&2
    exit 1
fi
echo "PASS: G2 activation section header present"

if ! grep -q 'from subscription_gate import activate_included_pro' "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: install.sh does not import activate_included_pro" >&2
    exit 1
fi
echo "PASS: install.sh imports activate_included_pro"

if ! grep -q "vendor', 'cm041', 'assistant_api'" "$INSTALL_SCRIPT"; then
    echo "FAIL [struct]: install.sh does not reference vendored cm041/assistant_api path" >&2
    exit 1
fi
echo "PASS: install.sh references vendored cm041/assistant_api path"

# ── Structural sanity: 4 new MSG_* keys present in catalogue ──
for key in \
    MSG_INFO_INCLUDED_PRO_ACTIVATING \
    MSG_OK_INCLUDED_PRO_ACTIVATED \
    MSG_WARN_INCLUDED_PRO_FAILED_NONFATAL \
    MSG_INFO_SUBSCRIPTION_PRICING_HINT; do
    if ! grep -q "^${key}=" "$STRINGS_FILE"; then
        echo "FAIL [struct]: ${key} not defined in strings catalogue" >&2
        exit 1
    fi
    if ! grep -q "\"\$${key}\"\\|\"\$${key}_" "$INSTALL_SCRIPT" \
       && ! grep -qE "\\\$${key}([^A-Z_]|$)" "$INSTALL_SCRIPT"; then
        echo "FAIL [struct]: ${key} not referenced in install.sh" >&2
        exit 1
    fi
    echo "PASS: ${key} defined + referenced"
done

# ── USD-canonical check: pricing hint must use USD, no GBP/£ ──
# Locked 2026-05-27 (project_pricing_v1_0_locked_2026-05-27): USD is
# canonical for v1.0; GBP / £ must not appear in customer copy.
pricing=$(grep '^MSG_INFO_SUBSCRIPTION_PRICING_HINT=' "$STRINGS_FILE")
if ! grep -q '9.99 USD' <<<"$pricing"; then
    echo "FAIL [i18n]: pricing hint must use '9.99 USD' (USD-canonical v1.0)" >&2
    exit 1
fi
if echo "$pricing" | LC_ALL=C grep -qE 'GBP|\xc2\xa3'; then
    echo "FAIL [i18n]: pricing hint must not contain GBP or £ (USD-canonical v1.0)" >&2
    exit 1
fi
echo "PASS: pricing hint uses 9.99 USD"

# ── No-em-dash check on G2 strings ─────────────────────────────
for key in \
    MSG_INFO_INCLUDED_PRO_ACTIVATING \
    MSG_OK_INCLUDED_PRO_ACTIVATED \
    MSG_WARN_INCLUDED_PRO_FAILED_NONFATAL \
    MSG_INFO_SUBSCRIPTION_PRICING_HINT; do
    val=$(grep "^${key}=" "$STRINGS_FILE")
    # U+2014 EM DASH is forbidden per CM051 style rule.
    if echo "$val" | LC_ALL=C grep -q $'\xe2\x80\x94'; then
        echo "FAIL [style]: ${key} contains an em-dash; use en-dash or hyphen" >&2
        exit 1
    fi
done
echo "PASS: no em-dashes in G2 strings"

# ── Functional probe: activate_included_pro writes state ──
STATE_FILE="/tmp/test-state-g2-$$.json"
trap "rm -f '${STATE_FILE}'" EXIT INT TERM

# Run the same Python snippet that install.sh's activation block runs,
# but with OSTLER_SUBSCRIPTION_STATE pointing at a synthetic temp file.
# This is the exact contract install.sh depends on. If this works in
# isolation, the install.sh block will too (subject to ${SCRIPT_DIR}
# resolution which is parse-checked above).
OSTLER_SUBSCRIPTION_STATE="${STATE_FILE}" python3 -c "
import sys, os
sys.path.insert(0, os.path.join('${REPO_ROOT}', 'vendor', 'cm041', 'assistant_api'))
from subscription_gate import activate_included_pro
from datetime import datetime, timezone
activate_included_pro(datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z'))
"

if [[ ! -f "${STATE_FILE}" ]]; then
    echo "FAIL [func]: activate_included_pro did not write state file at ${STATE_FILE}" >&2
    exit 1
fi
echo "PASS: state file written"

# ── State-file shape assertions ─────────────────────────────────
python3 - "${STATE_FILE}" <<'PYEOF'
import json
import sys
from datetime import datetime, timedelta, timezone

state_path = sys.argv[1]
with open(state_path) as f:
    state = json.load(f)

assert state.get("status") == "active", f"status != active: {state.get('status')}"
print("PASS: status == active")

assert state.get("source") == "first_month_free", f"source != first_month_free: {state.get('source')}"
print("PASS: source == first_month_free")

expires_iso = state.get("expires_at")
assert expires_iso, "expires_at missing"
expires = datetime.fromisoformat(expires_iso.replace("Z", "+00:00"))
delta_days = (expires - datetime.now(timezone.utc)).days
# 180 days +/- 1 day tolerance for clock jitter at the boundary
assert 178 <= delta_days <= 181, f"expires_at not ~180 days out: {delta_days} days"
print(f"PASS: expires_at ~180 days out ({delta_days} days)")

grace_iso = state.get("grace_period_end")
assert grace_iso, "grace_period_end missing"
grace = datetime.fromisoformat(grace_iso.replace("Z", "+00:00"))
grace_delta = (grace - datetime.now(timezone.utc)).days
# 180 + 14 grace = ~194 days; +/- 1 day tolerance
assert 192 <= grace_delta <= 195, f"grace_period_end not ~194 days out: {grace_delta} days"
print(f"PASS: grace_period_end ~194 days out ({grace_delta} days)")
PYEOF

echo ""
echo "ALL TESTS PASSED: G2 included-Pro activation"
