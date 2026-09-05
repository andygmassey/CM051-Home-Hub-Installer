#!/usr/bin/env bash
# ============================================================================
# test_verify_commit_parity_gate.sh -- prove the commit-parity gate FIRES.
#
# Per feedback_gate_must_prove_it_fires_not_just_compile: every gate PR
# needs negative-case tests proving the gate REJECTS violations, not just
# CI-green. A silent no-op gate is worse than no gate -- HR015 #225's class
# of bug (stale wrapper + fresh daemon) shipped past every existing gate.
#
# STRATEGY
# --------
# We can't fabricate real Mach-O binaries with embedded env!() strings in
# a shell fixture, so we route the `strings` invocation through the
# $STRINGS_CMD env var and inject a shim binary whose stdout is chosen
# per fixture path.
#
# Layout:
#   fixture/
#     Fake.dmg-mount/
#       OstlerInstaller.app/                       (outer wrapper)
#         Contents/Resources/
#           Ostler.app/Contents/MacOS/
#             zeroclaw-desktop                     (fake wrapper binary)
#           assistant-agent/OstlerAssistant.app/Contents/MacOS/
#             ostler-assistant                     (fake daemon binary)
#
# The shim reads a `STRINGS_FAKE_STATE` file whose lines are
# `<path-substring> <string-to-emit>` (first substring match wins). This
# gives fine-grained control per test case: emit a specific 40-hex commit
# for the wrapper, a different one for the daemon, or none at all.
# ============================================================================
set -uo pipefail    # NOT -e: we WANT to run all cases even when one fails.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
REPO_DIR="$(cd "${SCRIPTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_commit_parity.sh"
MAKEFILE="${REPO_DIR}/gui/Makefile"

[[ -x "${GATE}" ]] || { echo "FIXTURE: chmod +x ${GATE}"; chmod +x "${GATE}"; }

TMP="$(mktemp -d -t verify_commit_parity_gate_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# ----- fixture DMG-mount ----------------------------------------------------
MOUNT="${TMP}/Fake.dmg-mount"
WRAPPER_BIN="${MOUNT}/OstlerInstaller.app/Contents/Resources/Ostler.app/Contents/MacOS/zeroclaw-desktop"
DAEMON_BIN="${MOUNT}/OstlerInstaller.app/Contents/Resources/assistant-agent/OstlerAssistant.app/Contents/MacOS/ostler-assistant"
mkdir -p "$(dirname "${WRAPPER_BIN}")" "$(dirname "${DAEMON_BIN}")"
# Fixture files contain nothing: the shim controls what "strings" returns.
: > "${WRAPPER_BIN}"
: > "${DAEMON_BIN}"

# THE WRAPPER'S Info.plist, WITHOUT WHICH EVERY CASE BELOW DIES AT CASE 0.
#
# This fixture predates the gate reading CFBundleExecutable. It created
# Ostler.app/Contents/MacOS/zeroclaw-desktop and no Contents/Info.plist, because
# the gate used to hardcode the binary name. When the gate started resolving the
# name from the plist, the fixture went stale and every assertion after the
# resolve became unreachable -- and nothing noticed, because no workflow has ever
# run this file.
#
# Written as literal XML rather than through PlistBuddy so the fixture does not
# depend on the tool whose failure mode this gate exists to survive.
mkdir -p "$(dirname "${WRAPPER_BIN}")/.."
cat > "$(dirname "$(dirname "${WRAPPER_BIN}")")/Info.plist" <<'WRAPPERPLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>zeroclaw-desktop</string>
</dict>
</plist>
WRAPPERPLIST

# ----- strings shim ---------------------------------------------------------
# Reads STRINGS_FAKE_STATE. Each line is `<pattern> <string-to-emit>`.
# Pattern grammar: substring match (`*pattern*`). First match wins; a
# non-matching call emits nothing (empty stdout) which is what real
# `strings` on a stripped binary would do.
SHIM="${TMP}/fake_strings.sh"
cat > "${SHIM}" <<'SHIM_EOF'
#!/usr/bin/env bash
target="${1:-}"
state="${STRINGS_FAKE_STATE:-}"
[[ -z "${state}" || ! -f "${state}" ]] && exit 0
while IFS=' ' read -r pattern output; do
    [[ -z "${pattern}" ]] && continue
    case "${target}" in
        *"${pattern}"*)
            printf '%s\n' "${output}"
            exit 0
            ;;
    esac
done < "${state}"
# No match -> emit nothing, exit 0.
exit 0
SHIM_EOF
chmod +x "${SHIM}"

PASS=0; FAIL=0
run_case() {
    local name="$1" state_file="$2" expected_rc="$3"
    local capture="${TMP}/case_$$.out"
    printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${expected_rc}"
    STRINGS_CMD="${SHIM}" STRINGS_FAKE_STATE="${state_file}" \
        "${GATE}" --mount "${MOUNT}" >"${capture}" 2>&1
    local rc=$?
    sed 's/^/  | /' "${capture}"
    if [[ "${rc}" -eq "${expected_rc}" ]]; then
        printf 'PASS: %s (rc=%s)\n' "${name}" "${rc}"
        PASS=$((PASS+1))
    else
        printf 'FAIL: %s got rc=%s, expected %s\n' "${name}" "${rc}" "${expected_rc}" >&2
        FAIL=$((FAIL+1))
    fi
    LAST_CAPTURE="${capture}"
}

assert_contains() {
    local name="$1" needle="$2"
    if grep -qF -- "${needle}" "${LAST_CAPTURE}"; then
        printf 'PASS: %s (output contains %q)\n' "${name}" "${needle}"
        PASS=$((PASS+1))
    else
        printf 'FAIL: %s (output missing %q)\n' "${name}" "${needle}" >&2
        FAIL=$((FAIL+1))
    fi
}

assert_not_contains() {
    # The mirror of assert_contains. A gate that names the WRONG subject is a
    # gate that sends the next reader down the wrong path, so "must not say X"
    # is as much an assertion as "must say Y".
    local label="$1" needle="$2"
    if grep -qF -- "${needle}" "${LAST_CAPTURE}"; then
        printf 'FAIL: %s (output wrongly contains %q)\n' "${label}" "${needle}" >&2
        FAIL=$((FAIL+1))
    else
        printf 'PASS: %s\n' "${label}"
        PASS=$((PASS+1))
    fi
}

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"    # 40 hex 'a'
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"    # 40 hex 'b'

# --- CASE 1: both markers present + EQUAL -> gate GREEN (rc 0) --------------
STATE1="${TMP}/state_matching"
cat > "${STATE1}" <<EOF
zeroclaw-desktop WRAPPER_FRONTEND_COMMIT=${SHA_A}
ostler-assistant DAEMON_FRONTEND_COMMIT=${SHA_A}
EOF
run_case "both markers present + equal" "${STATE1}" 0
assert_contains "case 1 reports the matching sha" "daemon=${SHA_A} wrapper=${SHA_A}"

# --- CASE 2: both present + DIFFERENT (the v1.0.13 bug shape) -> RED (rc 1) --
STATE2="${TMP}/state_mismatch"
cat > "${STATE2}" <<EOF
zeroclaw-desktop WRAPPER_FRONTEND_COMMIT=${SHA_B}
ostler-assistant DAEMON_FRONTEND_COMMIT=${SHA_A}
EOF
run_case "wrapper != daemon (v1.0.13 stale-wrapper shape)" "${STATE2}" 1
assert_contains "case 2 error names the daemon sha" "daemon=${SHA_A}"
assert_contains "case 2 error names the wrapper sha" "wrapper=${SHA_B}"
assert_contains "case 2 error cites HR015 #226" "HR015 #226"

# --- CASE 3: wrapper marker MISSING (pre-#226 wrapper) -> RED ---------------
STATE3="${TMP}/state_wrapper_absent"
cat > "${STATE3}" <<EOF
ostler-assistant DAEMON_FRONTEND_COMMIT=${SHA_A}
EOF
run_case "wrapper carries no marker (pre-#226 build)" "${STATE3}" 1
assert_contains "case 3 error names the wrapper as culprit" "wrapper binary carries no WRAPPER_FRONTEND_COMMIT marker"
assert_contains "case 3 error tells caller to rebuild wrapper" "cargo tauri build --release"

# --- CASE 4: daemon marker MISSING (pre-#226 daemon) -> RED -----------------
STATE4="${TMP}/state_daemon_absent"
cat > "${STATE4}" <<EOF
zeroclaw-desktop WRAPPER_FRONTEND_COMMIT=${SHA_A}
EOF
run_case "daemon carries no marker (pre-#226 build)" "${STATE4}" 1
assert_contains "case 4 error names the daemon as culprit" "daemon binary carries no DAEMON_FRONTEND_COMMIT marker"

# --- CASE 4b: the wrapper's Info.plist is UNREADABLE ------------------------
#
# PLISTBUDDY WRITES ITS ERROR TO STDOUT. On a missing plist it prints
# a "file does not exist" sentence naming the path, on stdout, so `2>/dev/null` does not
# suppress it and a `[[ -n ... ]]` check PASSES on the error sentence. The gate
# then used that sentence as the executable NAME and died with "wrapper binary
# not found in DMG payload" -- naming the wrapper when the PLIST was the problem,
# and making its own "declares no CFBundleExecutable" message unreachable.
#
# This case removes the plist and asserts the gate names the PLIST. Without it
# the fix is untested: every other case supplies a valid plist, so none of them
# can tell a hardened read from the old one. (Measured: reverting the gate fix
# alone leaves all other cases GREEN.)
printf '\n=== CASE: wrapper Info.plist unreadable -> the gate must name the PLIST ===\n'
_SAVED_PLIST="${TMP}/saved-wrapper-Info.plist"
_WRAPPER_PLIST_PATH="$(dirname "$(dirname "${WRAPPER_BIN}")")/Info.plist"
mv "${_WRAPPER_PLIST_PATH}" "${_SAVED_PLIST}"
# rc=2, not 1: the gate separates a PRECONDITION it could not read from a
# parity MISMATCH it measured. Expecting 1 here would assert the wrong
# contract and quietly bless a gate that stopped distinguishing them.
run_case "wrapper Info.plist missing" "${STATE1}" 2
assert_contains "case 4b names the CFBundleExecutable/plist, not the binary" "CFBundleExecutable"
assert_not_contains "case 4b does NOT blame the wrapper binary" "wrapper binary not found"
mv "${_SAVED_PLIST}" "${_WRAPPER_PLIST_PATH}"

# --- CASE 5: Makefile wire-in assertion (silent no-op guard) ----------------
# feedback_gate_must_prove_it_fires_not_just_compile: also prove the gate
# is actually invoked by make ship. Expect >=3 hits: .PHONY entry, target
# definition, ship-chain slot.
printf '\n=== CASE: gui/Makefile wires the gate into `make ship` ===\n'
if [[ ! -f "${MAKEFILE}" ]]; then
    printf 'FAIL: gui/Makefile not found at %s\n' "${MAKEFILE}" >&2
    FAIL=$((FAIL+1))
else
    HITS="$(grep -c 'verify-commit-parity' "${MAKEFILE}")"
    printf '  gui/Makefile mentions verify-commit-parity %d time(s)\n' "${HITS}"
    if [[ "${HITS}" -ge 3 ]]; then
        printf 'PASS: Makefile wire-in (>=3 mentions: phony, target, ship-chain)\n'
        PASS=$((PASS+1))
    else
        printf 'FAIL: expected >=3 mentions (phony + target + ship-chain slot), got %d\n' "${HITS}" >&2
        FAIL=$((FAIL+1))
    fi
    if grep -qE '^ship:.*verify-commit-parity' "${MAKEFILE}"; then
        printf 'PASS: ship: recipe includes verify-commit-parity in the chain\n'
        PASS=$((PASS+1))
    else
        printf 'FAIL: ship: recipe does not include verify-commit-parity\n' >&2
        FAIL=$((FAIL+1))
    fi
fi

printf '\n============================================================\n'
printf 'Commit-parity-gate self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
