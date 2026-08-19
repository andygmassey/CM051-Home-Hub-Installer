#!/usr/bin/env bash
# ============================================================================
# test_verify_stapling_gate.sh -- prove the stapling gate FIRES + is not a no-op.
#
# Per feedback_gate_must_prove_it_fires_not_just_compile: every gate PR needs
# negative-case tests proving the gate REJECTS violations, not just CI-green.
# A silent no-op gate is worse than no gate.
#
# STRATEGY
# --------
# We can't fabricate real notarisation tickets in a shell fixture, so we
# route the stapler invocation through the $STAPLER_CMD env var and
# inject a shim binary whose exit code is chosen per fixture path.
#
# Layout:
#   fixture/
#     Fake.dmg-mount/
#       OstlerInstaller.app/                       (outer wrapper)
#         Contents/Resources/
#           Ostler.app/                            (nested Hub)
#           assistant-agent/OstlerAssistant.app/   (nested daemon)
#
# We create a shim that reads a `STAPLER_FAKE_STATE` file whose lines
# are `<path-substring> <exit-code>`; matching is first-substring-wins.
# This gives fine-grained control per test case: "make the daemon
# report unstapled, the rest pass" and so on.
# ============================================================================
set -uo pipefail    # NOT -e: we WANT to run all cases even when one fails.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
GATE="${SCRIPTS_DIR}/verify_stapling.sh"

[[ -x "${GATE}" ]] || { echo "FIXTURE: chmod +x ${GATE}"; chmod +x "${GATE}"; }

TMP="$(mktemp -d -t verify_stapling_gate_XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT

# ----- fixture DMG-mount ----------------------------------------------------
MOUNT="${TMP}/Fake.dmg-mount"
mkdir -p "${MOUNT}/OstlerInstaller.app/Contents/Resources/Ostler.app"
mkdir -p "${MOUNT}/OstlerInstaller.app/Contents/Resources/assistant-agent/OstlerAssistant.app"

# ----- stapler shim ---------------------------------------------------------
# Reads STAPLER_FAKE_STATE. Each line is `<pattern> <rc>`.
# Pattern grammar:
#   `foo`   -- substring match (`*foo*`) -- catches all paths containing foo
#   `=foo`  -- exact-endswith match (`*foo`) -- ONLY paths ending in foo
# First match wins; default rc is 0 (stapled).
SHIM="${TMP}/fake_stapler.sh"
cat > "${SHIM}" <<'SHIM_EOF'
#!/usr/bin/env bash
target="${1:-}"
state="${STAPLER_FAKE_STATE:-}"
[[ -z "${state}" || ! -f "${state}" ]] && exit 0
while IFS=' ' read -r pattern rc; do
    [[ -z "${pattern}" ]] && continue
    if [[ "${pattern}" = "="* ]]; then
        suffix="${pattern#=}"
        case "${target}" in *"${suffix}") exit "${rc}" ;; esac
    else
        case "${target}" in *"${pattern}"*) exit "${rc}" ;; esac
    fi
done < "${state}"
exit 0
SHIM_EOF
chmod +x "${SHIM}"

PASS=0; FAIL=0
run_case() {
    local name="$1" state_file="$2" expected_rc="$3"
    printf '\n=== CASE: %s (expect rc=%s) ===\n' "${name}" "${expected_rc}"
    STAPLER_CMD="${SHIM}" STAPLER_FAKE_STATE="${state_file}" \
        "${GATE}" --mount "${MOUNT}"
    local rc=$?
    if [[ "${rc}" -eq "${expected_rc}" ]]; then
        printf 'PASS: %s (rc=%s)\n' "${name}" "${rc}"
        PASS=$((PASS+1))
    else
        printf 'FAIL: %s got rc=%s, expected %s\n' "${name}" "${rc}" "${expected_rc}" >&2
        FAIL=$((FAIL+1))
    fi
}

# --- CASE 1: everything stapled -> gate GREEN (rc 0) ------------------------
STATE1="${TMP}/state_all_stapled"
: > "${STATE1}"    # empty state => shim always returns 0
run_case "all stapled" "${STATE1}" 0

# --- CASE 2: Ostler.app unstapled (the actual #221 bug) -> gate RED (rc 1) --
STATE2="${TMP}/state_ostler_unstapled"
cat > "${STATE2}" <<EOF
/Ostler.app 65
EOF
run_case "Ostler.app unstapled (bug #221 shape)" "${STATE2}" 1

# --- CASE 3: OstlerAssistant.app unstapled -> gate RED ---------------------
STATE3="${TMP}/state_daemon_unstapled"
cat > "${STATE3}" <<EOF
OstlerAssistant.app 65
EOF
run_case "OstlerAssistant.app unstapled" "${STATE3}" 1

# --- CASE 4: only the OstlerInstaller.app OUTER unstapled -> gate RED ------
# Uses the `=` exact-endswith pattern so the shim ONLY marks the outer
# unstapled (nested apps' paths don't end in `/OstlerInstaller.app`).
STATE4="${TMP}/state_outer_unstapled_only"
cat > "${STATE4}" <<EOF
=/OstlerInstaller.app 65
EOF
run_case "outer OstlerInstaller.app unstapled (only)" "${STATE4}" 1

# --- CASE 5: multiple failures at once -> gate RED, both listed ------------
STATE5="${TMP}/state_multi_unstapled"
cat > "${STATE5}" <<EOF
/Ostler.app 65
OstlerAssistant.app 65
EOF
run_case "Ostler.app AND OstlerAssistant.app both unstapled" "${STATE5}" 1

printf '\n============================================================\n'
printf 'Stapling-gate self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
printf '============================================================\n'
exit "${FAIL}"
