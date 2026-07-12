#!/usr/bin/env bash
#
# tests/test_install_license_enforcement.sh
#
# SECURITY regression test for the install.sh licence-gate bypass.
#
# Before this fix the shell installer fail-SOFT on a missing / malformed
# licence ("Licence not found... Install continues"), so running
# install.sh directly bypassed the GUI's Ed25519 signature enforcement.
# The fix makes the shell path ENFORCE a GUI-validated licence artefact
# in production and HARD-FAIL without one, with an explicit dev/CI escape
# (OSTLER_DEV=1 / --allow-unlicensed).
#
# This is a BEHAVIOURAL test: it extracts the real gate functions
# (_license_gate_reject + au1_persist_license) and the LICENSE_ENFORCE
# decision block VERBATIM from install.sh and drives them under each
# scenario, rather than grepping for their presence. Stubs stand in for
# the installer's warn/ok/fail_with_code helpers; fail_with_code exits
# non-zero exactly as the real one does (fail -> exit 1).

set -uo pipefail   # NOT -e: we intentionally probe non-zero exits

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install.sh"
FAILED=0
fail_t() { echo "FAIL: $*" >&2; FAILED=1; }
pass_t() { echo "ok:   $*"; }

if [[ ! -f "$INSTALL_SH" ]]; then
    echo "FAIL: install.sh not found at $INSTALL_SH" >&2
    exit 1
fi

# ── Extract the licence-gate functions verbatim ────────────────────
GATE_SRC="$(awk '
  /^_license_gate_reject\(\) \{/{f=1}
  /^au1_persist_license \|\| true/{f=0}
  f{print}
' "$INSTALL_SH")"

if [[ -z "$GATE_SRC" ]]; then
    echo "FAIL: could not extract licence-gate functions from install.sh" >&2
    exit 1
fi
grep -q '_license_gate_reject()' <<<"$GATE_SRC" || fail_t "extract missing _license_gate_reject()"
grep -q 'au1_persist_license()'  <<<"$GATE_SRC" || fail_t "extract missing au1_persist_license()"

# ── Extract the LICENSE_ENFORCE decision block verbatim ────────────
DECISION_SRC="$(awk '
  /^if \[\[ "\$\{OSTLER_DEV:-0\}" == "1" \|\| "\$ALLOW_UNLICENSED" == true \]\]; then/{f=1}
  f{print}
  f && /^fi$/{exit}
' "$INSTALL_SH")"

if [[ -z "$DECISION_SRC" ]]; then
    fail_t "could not extract LICENSE_ENFORCE decision block from install.sh"
fi

# ── Scenario driver ────────────────────────────────────────────────
# run_gate <enforce true|false> <license-json-or-empty> -> exit status
run_gate() {
    local enforce="$1"; local contents="$2"
    local tmp; tmp="$(mktemp -d)"
    (
        OSTLER_FINAL_DIR="$tmp"
        LICENSE_ENFORCE="$enforce"
        # Installer helper stubs. fail_with_code terminates the process
        # like the real fail() (exit 1), so a production reject aborts.
        warn() { echo "[warn] $*"; }
        ok()   { echo "[ok] $*"; }
        fail_with_code() { echo "[fail] $1: ${*:2}"; exit 1; }
        eval "$GATE_SRC"
        if [[ -n "$contents" ]]; then
            mkdir -p "$tmp/license"
            printf '%s' "$contents" > "$tmp/license/license.json"
        fi
        au1_persist_license
    ) >/dev/null 2>&1
    local rc=$?
    rm -rf "$tmp"
    return $rc
}

# A well-formed GUI-validated artefact (UUID-v4 license_id + Ed25519
# signature field). The signature bytes are opaque to the shell gate;
# cryptographic verification is the GUI verifier's job.
VALID_LIC='{"version":1,"license_id":"8c7e3f9a-1234-4abc-9def-0123456789ab","issued_to_email":"a@b.com","purchased_at":"2026-01-01T00:00:00Z","update_window_expires_at":"2099-01-01T00:00:00Z","max_hardware_fingerprints":3,"stripe_payment_id":"pi_TEST","signature_algorithm":"Ed25519","signature":"c2lnbmF0dXJlYnl0ZXM="}'
# A hand-crafted file carrying only a plausible UUID, no signature.
UUID_ONLY='{"license_id":"8c7e3f9a-1234-4abc-9def-0123456789ab"}'
# A non-UUID licence_id.
BAD_UUID='{"license_id":"not-a-uuid","signature_algorithm":"Ed25519","signature":"eA=="}'

# ── Scenario 1: production + no licence => REFUSES ─────────────────
if run_gate true ""; then
    fail_t "production + no licence should REFUSE the install, but au1 returned success"
else
    pass_t "production + no licence: install refuses (hard-fail)"
fi

# ── Scenario 2: dev escape + no licence => PROCEEDS ────────────────
if run_gate false ""; then
    pass_t "dev escape + no licence: install proceeds (fail-soft)"
else
    fail_t "dev escape + no licence should PROCEED, but au1 hard-failed"
fi

# ── Scenario 3: production + valid licence => PROCEEDS ─────────────
if run_gate true "$VALID_LIC"; then
    pass_t "production + valid GUI-validated licence: install proceeds"
else
    fail_t "production + valid licence should PROCEED, but au1 hard-failed"
fi

# ── Scenario 4: production + UUID-only (no signature) => REFUSES ───
# A hand-crafted file with only a UUID must not satisfy production
# enforcement -- otherwise the "require the GUI artefact" gate is
# trivially forgeable.
if run_gate true "$UUID_ONLY"; then
    fail_t "production + UUID-only (no signature) should REFUSE, but au1 returned success"
else
    pass_t "production + UUID-only (no signature): install refuses"
fi

# ── Scenario 5: production + non-UUID licence_id => REFUSES ────────
if run_gate true "$BAD_UUID"; then
    fail_t "production + non-UUID licence_id should REFUSE, but au1 returned success"
else
    pass_t "production + non-UUID licence_id: install refuses"
fi

# ── Scenario 6: dev escape + malformed licence => PROCEEDS ─────────
if run_gate false "$UUID_ONLY"; then
    pass_t "dev escape + malformed licence: install proceeds (fail-soft)"
else
    fail_t "dev escape + malformed licence should PROCEED, but au1 hard-failed"
fi

# ── Decision block: OSTLER_DEV / --allow-unlicensed => enforce=false
# Drive the real decision block bytes with different inputs.
check_decision() {
    local desc="$1"; local dev="$2"; local allow="$3"; local want="$4"
    local got
    got="$(
        OSTLER_DEV="$dev"
        ALLOW_UNLICENSED="$allow"
        eval "$DECISION_SRC"
        echo "$LICENSE_ENFORCE"
    )"
    if [[ "$got" == "$want" ]]; then
        pass_t "decision: ${desc} => LICENSE_ENFORCE=${got}"
    else
        fail_t "decision: ${desc} => LICENSE_ENFORCE=${got}, expected ${want}"
    fi
}
# Default (no dev, no flag) => production enforcement ON.
check_decision "no dev, no flag"        "0" "false" "true"
# OSTLER_DEV=1 => enforcement OFF.
check_decision "OSTLER_DEV=1"           "1" "false" "false"
# --allow-unlicensed => enforcement OFF.
check_decision "--allow-unlicensed"     "0" "true"  "false"

# ── Result ─────────────────────────────────────────────────────────
if [[ "$FAILED" -ne 0 ]]; then
    echo "test_install_license_enforcement: FAILED" >&2
    exit 1
fi
echo "PASS: tests/test_install_license_enforcement.sh (licence gate enforced in production, dev escape works)"
