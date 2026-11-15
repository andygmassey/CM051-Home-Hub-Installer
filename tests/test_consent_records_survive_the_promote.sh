#!/usr/bin/env bash
#
# test_consent_records_survive_the_promote.sh
#
# MEASURED on Mini16, v1.0.116, 2026-10-22: on a fresh install every consent
# record was lost. Section "3.6b" of install.sh persists region.json and
# consent.json while OSTLER_DIR is still the prelaunch staging tree, but
# ostler_security resolves posture/ from OSTLER_HOME (consent.py:70), which
# defaults to the FINAL ~/.ostler. The writes landed in the final posture/,
# and _ostler_promote_prelaunch_tree then rm -rf'd that directory and moved the
# staged posture/ (holding only enrichment-decision.json) over it.
#
# This test runs the REAL 3.6b block and the REAL promote function, both
# extracted from install.sh, against the REAL vendored ostler_security, with
# BOTH trees holding a posture/ directory, then asks whether the three files
# the block writes are in the final tree. HOME is a mktemp dir throughout.
#
# Outcomes: 0 PASS, 1 FAIL, 2 CANNOT-RUN (never reported as a pass).
# Needs python3 with `cryptography` (ostler_security/__init__ imports it).
#
# Env: INSTALL_SH=<path> runs against another install.sh (mutation / baseline).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-$REPO_ROOT/install.sh}"
FAILED=0
pass()       { echo "ok: $*"; }
failure()    { echo "FAIL: $*" >&2; FAILED=1; }
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }

[ -f "$INSTALL_SH" ] || cannot_run "no install.sh at $INSTALL_SH"
command -v python3 >/dev/null || cannot_run "no python3"
PYTHONPATH="$REPO_ROOT/vendor" python3 -c 'import ostler_security.consent_cli, legal' 2>/dev/null \
    || cannot_run "vendored ostler_security/legal not importable (pip install cryptography)"

PROMOTE_FN="$(awk '/^_ostler_promote_prelaunch_tree\(\) \{$/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALL_SH")"
[ "$(printf '%s\n' "$PROMOTE_FN" | grep -c .)" -ge 20 ] || cannot_run "promote function not extracted"

PERSIST_BLOCK="$(awk '/^if \[\[ "\$HAS_SECURITY_MODULE" == true \]\]; then$/{getline nx; if (nx ~ /MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION/){f=1; print; print nx; next}} f{print} f&&/^fi$/{exit}' "$INSTALL_SH")"
[ "$(printf '%s\n' "$PERSIST_BLOCK" | grep -c .)" -ge 40 ] || cannot_run "3.6b persist block not extracted"
grep -q 'consent_cli record' <<< "$PERSIST_BLOCK" || cannot_run "extracted block has no consent_cli record call"

SANDBOX="$(mktemp -d)" || cannot_run "no sandbox"
trap 'rm -rf "$SANDBOX"' EXIT
FAKE_HOME="$SANDBOX/home"
FINAL="$FAKE_HOME/.ostler"
STAGING="$FINAL/.ostler-prelaunch.TEST"

# $1 = "stale" seeds a stale final posture/ with a decoy, as a re-run would.
run_install_slice() {
    rm -rf "$SANDBOX/home"; mkdir -p "$FINAL/posture" "$STAGING/posture" "$STAGING/state"
    env -u OSTLER_HOME HOME="$FAKE_HOME" PYTHONPATH="$REPO_ROOT/vendor" bash -c '
        set -o pipefail
        OSTLER_FINAL_DIR="$1"; OSTLER_PRELAUNCH_DIR="$2"; OSTLER_DIR="$2"
        OSTLER_PRELAUNCH_PROMOTED=false
        OSTLER_PYTHON="$(command -v python3)"
        HAS_SECURITY_MODULE=true
        USER_ID=synthetic-user
        OSTLER_REGION=uk; OSTLER_REGION_ISO=GB; OSTLER_REGION_SOURCE=test
        OSTLER_CONSENT_ARTICLE_9_DECISION=""; OSTLER_CONSENT_VOICE_EU_DECISION=""
        OSTLER_CONSENT_THIRD_PARTY_DECISION=accepted
        OSTLER_CONSENT_PERSONAL_USE_DECISION=accepted
        OSTLER_CONSENT_SPOKEN_CAPTURE_DECISION=declined
        OSTLER_CONSENT_ENRICHMENT_DECISION=declined
        MSG_INFO_PERSISTING_CONSENT_RECORDS_REGION=x; MSG_WARN_COULD_NOT_PERSIST_REGION_JSON_CONTINUING=x
        MSG_WARN_CONSENT_CLI_STDERR_FIRST_400_CHARS=x; MSG_WARN_ENRICHMENT_DECISION_NOT_PERSISTED=x
        MSG_OK_CONSENT_RECORDS_REGION_PERSISTED_OSTLER_POSTURE=x
        _OSTLER_RUN_ERRORS=0
        info() { :; }; ok() { :; }; warn() { echo "WARN: $*" >&2; }
        err() { _OSTLER_RUN_ERRORS=$((_OSTLER_RUN_ERRORS+1)); echo "ERR: $*" >&2; }
        _ostler_quiesce_interval_agents() { :; }
        _ostler_set_paths() { OSTLER_DIR="$1"; }
        _ostler_lock_home_dir() { chmod 700 "$1"; }
        _ostler_repair_venv_after_promote() { :; }; _ostler_promote_venv_note() { :; }
        fail_with_code() { echo "FAIL_WITH_CODE: $*" >&2; exit 9; }
        eval "$4"
        eval "$3"
        _ostler_promote_prelaunch_tree
        echo "RUN_ERRORS=${_OSTLER_RUN_ERRORS}"
    ' _ "$FINAL" "$STAGING" "$PERSIST_BLOCK" "$PROMOTE_FN"
}

echo "== control: the promote really replaces a posture/ written to the final tree =="
rm -rf "$SANDBOX/home"; mkdir -p "$FINAL/posture" "$STAGING/posture"
echo decoy > "$FINAL/posture/control.json"; echo staged > "$STAGING/posture/staged.json"
env HOME="$FAKE_HOME" bash -c '
    OSTLER_FINAL_DIR="$1"; OSTLER_PRELAUNCH_DIR="$2"; OSTLER_DIR="$2"; OSTLER_PRELAUNCH_PROMOTED=false
    _ostler_quiesce_interval_agents() { :; }; _ostler_set_paths() { OSTLER_DIR="$1"; }
    _ostler_lock_home_dir() { chmod 700 "$1"; }; fail_with_code() { exit 9; }
    eval "$3"; _ostler_promote_prelaunch_tree' _ "$FINAL" "$STAGING" "$PROMOTE_FN" >/dev/null 2>&1
[ ! -e "$FINAL/posture/control.json" ] || cannot_run "promote did not replace the final posture/; the hazard is gone and this test would be vacuous"
[ -e "$FINAL/posture/staged.json" ] || cannot_run "staged posture/ did not arrive; harness cannot see a success"
pass "control: final posture/ is replaced, staged posture/ arrives"

echo "== subject: 3.6b persist then promote =="
OUT="$(run_install_slice 2>&1)"; RC=$?
echo "$OUT" | sed 's/^/    /'
[ "$RC" -eq 0 ] || cannot_run "slice exited $RC"
for f in consent.json region.json enrichment-decision.json; do
    if [ -s "$FINAL/posture/$f" ]; then pass "$f present in final posture/"
    else failure "$f MISSING from final posture/ after the promote"; fi
done
for tb in third_party_data_personal_records personal_use_only spoken_capture_recording_consent; do
    if grep -q "\"$tb\"" "$FINAL/posture/consent.json" 2>/dev/null; then pass "tickbox $tb recorded in final consent.json"
    else failure "tickbox $tb not in final consent.json"; fi
done
if grep -q '^RUN_ERRORS=0$' <<< "$OUT"; then pass "no install error raised by the post-promote assertion"
else echo "note: post-promote assertion raised an error (expected on a baseline that loses consent)"; fi

echo
[ "$FAILED" -eq 0 ] && { echo "PASS: consent records survive the promote"; exit 0; }
echo "FAILED" >&2; exit 1
