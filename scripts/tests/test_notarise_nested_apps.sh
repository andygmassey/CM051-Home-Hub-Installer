#!/usr/bin/env bash
# ============================================================================
# test_notarise_nested_apps.sh -- prove the nested-app notarisation step FIRES
# and FAILS CLOSED. Not a compile check.
#
# Per feedback_gate_must_prove_it_fires_not_just_compile: a step that silently
# no-ops is worse than no step. This one is exactly that shape -- the pre-seal
# staple loop it replaces soft-failed per bundle, printed a friendly "NOTE: no
# standalone ticket yet", returned 0, and let the cut burn a full package +
# notarise-dmg cycle before verify-stapling finally caught it at 2/3.
#
# STRATEGY
# --------
# Real notarisation can't happen in a fixture, so both Apple tools are routed
# through env vars the script honours (STAPLER_BIN / NOTARYTOOL_BIN) and
# replaced with shims that MODEL the real semantics rather than returning
# canned exit codes:
#
#   $FAKE_STATE_DIR/apple-ticket/<Bundle>.app  -- Apple's notary DB holds a
#                                                 ticket for this CDHash
#   $FAKE_STATE_DIR/stapled/<Bundle>.app       -- ticket is embedded in the
#                                                 bundle on disk
#
#   stapler validate  -> 0 iff stapled/ marker exists
#   stapler staple    -> 0 + creates stapled/ marker iff apple-ticket/ exists
#   notarytool submit -> creates apple-ticket/ for the submitted bundle
#
# Modelling it this way means a test can't accidentally assert a state machine
# that could never occur in a real cut -- which is how the first draft of this
# ladder produced three false failures.
#
# STAPLE_LIES=1 breaks the model deliberately: staple returns 0 without
# embedding anything. That is the only way to prove the script's SECOND pass
# (the final re-validate) is load-bearing rather than decorative.
# ============================================================================
set -uo pipefail    # NOT -e: run every case even when one fails.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TESTS_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/gui/scripts/notarise-nested-apps.sh"

[[ -f "${SCRIPT}" ]] || { echo "FATAL: ${SCRIPT} not found"; exit 2; }
[[ -x "${SCRIPT}" ]] || chmod +x "${SCRIPT}"

TMP="$(mktemp -d -t notarise_nested_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'

# ----- shims ----------------------------------------------------------------
STAPLER_SHIM="${TMP}/fake_stapler.sh"
cat > "${STAPLER_SHIM}" <<'SHIM_EOF'
#!/usr/bin/env bash
action="${1:-}"; shift || true
target="${1:-}"
name="$(basename "${target}")"
printf 'stapler %s %s\n' "${action}" "${name}" >> "${SHIM_LOG}"
case "${action}" in
    validate)
        [[ -f "${FAKE_STATE_DIR}/stapled/${name}" ]] && exit 0
        exit 1
        ;;
    staple)
        # STAPLE_LIES: report success without embedding anything.
        [[ "${STAPLE_LIES:-0}" = "1" ]] && exit 0
        if [[ -f "${FAKE_STATE_DIR}/apple-ticket/${name}" ]]; then
            touch "${FAKE_STATE_DIR}/stapled/${name}"
            exit 0
        fi
        exit 1
        ;;
esac
exit 0
SHIM_EOF
chmod +x "${STAPLER_SHIM}"

NOTARY_SHIM="${TMP}/fake_notarytool.sh"
cat > "${NOTARY_SHIM}" <<'SHIM_EOF'
#!/usr/bin/env bash
printf 'notarytool %s\n' "$*" >> "${SHIM_LOG}"
rc="${NOTARYTOOL_FAKE_RC:-0}"
[[ "${rc}" -ne 0 ]] && exit "${rc}"
# Accepted: Apple now holds a ticket for the bundle inside the submitted zip.
for arg in "$@"; do
    case "${arg}" in
        *.zip)
            base="$(basename "${arg}" .zip)"        # nested-notary-Ostler
            touch "${FAKE_STATE_DIR}/apple-ticket/${base#nested-notary-}.app"
            ;;
    esac
done
exit 0
SHIM_EOF
chmod +x "${NOTARY_SHIM}"

HUB="Ostler.app"
DAEMON="OstlerAssistant.app"

# ----- runner ---------------------------------------------------------------
# run_case <name> <expect-rc> <pre-ticketed csv> <pre-stapled csv> \
#          <notary-rc> <want-hub yes|no> <staple-lies 0|1>
run_case() {
    local name="$1" expect_rc="$2" ticketed="$3" stapled="$4"
    local notary_rc="$5" want_hub="${6:-yes}" staple_lies="${7:-0}"

    local app="${TMP}/case/OstlerInstaller.app"
    local state="${TMP}/fakestate"
    local log="${TMP}/shim.log"

    rm -rf "${TMP}/case" "${state}" "${TMP}/work"
    mkdir -p "${app}/Contents/Resources/assistant-agent/${DAEMON}/Contents/MacOS"
    printf 'daemon\n' > "${app}/Contents/Resources/assistant-agent/${DAEMON}/Contents/MacOS/ostler-assistant"
    if [[ "${want_hub}" = "yes" ]]; then
        mkdir -p "${app}/Contents/Resources/${HUB}/Contents/MacOS"
        printf 'hub\n' > "${app}/Contents/Resources/${HUB}/Contents/MacOS/Ostler"
    fi

    mkdir -p "${state}/apple-ticket" "${state}/stapled"
    local b
    for b in ${ticketed//,/ }; do [[ -n "${b}" ]] && touch "${state}/apple-ticket/${b}"; done
    # A stapled bundle implies Apple issued the ticket in the first place.
    for b in ${stapled//,/ }; do
        [[ -z "${b}" ]] && continue
        touch "${state}/stapled/${b}" "${state}/apple-ticket/${b}"
    done
    : > "${log}"

    local out rc
    out="$(
        STAPLER_BIN="${STAPLER_SHIM}" \
        NOTARYTOOL_BIN="${NOTARY_SHIM}" \
        FAKE_STATE_DIR="${state}" \
        NOTARYTOOL_FAKE_RC="${notary_rc}" \
        STAPLE_LIES="${staple_lies}" \
        SHIM_LOG="${log}" \
        bash "${SCRIPT}" "${app}" "test-profile" "${TMP}/work" 2>&1
    )"
    rc=$?

    LAST_LOG="${log}"
    if [[ "${rc}" -eq "${expect_rc}" ]]; then
        printf "${GREEN}PASS${NC} %s (rc=%d)\n" "${name}" "${rc}"
        PASS=$((PASS + 1)); return 0
    fi
    printf "${RED}FAIL${NC} %s (expected rc=%s, got rc=%d)\n" "${name}" "${expect_rc}" "${rc}"
    printf '%s\n' "${out}" | sed 's/^/       /'
    sed 's/^/       log: /' "${log}"
    FAIL=$((FAIL + 1)); return 1
}

# assert_submissions <expected-count>
assert_submissions() {
    local want="$1"
    local got
    got="$(grep -c 'notarytool submit' "${LAST_LOG}" || true)"
    if [[ "${got}" -eq "${want}" ]]; then
        printf "${GREEN}PASS${NC}   ^-- %s notary submission(s)\n" "${got}"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${NC}   ^-- expected %s notary submission(s), got %s\n" "${want}" "${got}"
        sed 's/^/       log: /' "${LAST_LOG}"
        FAIL=$((FAIL + 1))
    fi
}

echo "=== notarise-nested-apps.sh: fail-closed ladder ==="

# 1. Idempotent re-run: both already stapled -> pass without spending a
#    submission. Matters because the step sits mid-cut and gets re-run.
run_case "already stapled -> pass, no submission" 0 "" "${HUB},${DAEMON}" 0
assert_submissions 0

# 2. First-time path: nothing ticketed anywhere, notary accepts both.
run_case "no tickets -> submit both -> stapled" 0 "" "" 0
assert_submissions 2

# 3. Apple already holds tickets (unchanged CDHash from a previous cut):
#    staple takes directly, no submission burned.
run_case "ticket at Apple -> staple only" 0 "${HUB},${DAEMON}" "" 0
assert_submissions 0

# 4. THE REGRESSION THIS CLOSES. Hub has no ticket and notary rejects it.
#    Old code printed "NOTE: no standalone ticket yet" and returned 0.
run_case "Hub unticketed + notary rejects -> FAIL CLOSED" 1 "${DAEMON}" "${DAEMON}" 1
assert_submissions 1

# 5. Missing nested bundle is a hard error, not a skip (2026-05-21 Hub-less DMG).
run_case "missing Ostler.app -> FAIL CLOSED" 1 "" "${DAEMON}" 0 "no"
assert_submissions 0

# 6. The final re-verify must be load-bearing: staple claims success but the
#    ticket is not actually embedded. Without the second pass this returns 0.
run_case "staple lies -> final validate catches it" 1 "${HUB},${DAEMON}" "" 0 "yes" 1

# 7. Daemon-side failure fails the cut too -- install.sh copies BOTH bundles
#    out to /Applications, so both are load-bearing.
run_case "daemon unticketed + notary rejects -> FAIL CLOSED" 1 "${HUB}" "${HUB}" 1
assert_submissions 1

echo ""
echo "=== ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
exit 0
