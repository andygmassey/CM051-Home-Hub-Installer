#!/usr/bin/env bash
# probes/install_error_honesty.sh
# ============================================================================
# QUESTION: does the installer's own closing summary agree with the number of
#           errors actually present in its log?
#
# WHY IT MATTERS. Task #270: install.sh closed with "no errors detected" over a
# session containing 43 real errors. The customer is told the install was
# clean. It was not. Every later symptom then gets diagnosed against a false
# premise, which is more expensive than the original errors.
#
# THIS PROBE EXISTS TO DISTRUST A SUMMARY. The rule it enforces is the one that
# cost this project four release tags: never read a component's self-report as
# the result. Count the underlying thing yourself and compare.
#
# It deliberately does NOT assert "zero errors". A real install has benign
# errors -- a missing optional binary, a malformed row in a customer's export.
# What it asserts is AGREEMENT: the summary must not claim clean over a log
# that is not clean. A truthful "12 errors, see log" passes. A false "no
# errors detected" fails.
# ============================================================================

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/probe.sh"

PROBE_NAME="install_error_honesty"
PROBE_QUESTION="does the installer's closing summary agree with the error count in its own log?"

# OSTLER_DIR is ~/.ostler. The log is NOT under ~/Documents/Ostler/logs --
# that path was searched twice during the v1.0.31 walk and reported a false
# absence. install.sh:962 is the authority.
LOG_PATH="${OSTLER_INSTALL_LOG:-\$HOME/.ostler/logs/install.log}"

ERROR_PATTERN='ERROR|FATAL|Traceback|command not found|No such file or directory'
CLEAN_CLAIM_PATTERN='no errors detected|completed without errors|no problems found'

count_errors_in() {
    # count_errors_in <path>  -> integer on stdout
    local path="$1"
    if [ "${SELF_TEST_LOCAL:-0}" -eq 0 ]; then
        box_run "grep -cE '$ERROR_PATTERN' \"$path\" 2>/dev/null || echo 0"
    else
        grep -cE "$ERROR_PATTERN" "$path" 2>/dev/null || echo 0
    fi
}

claims_clean_in() {
    # Exits 0 if the log contains a clean-claim, 1 otherwise.
    local path="$1"
    if [ "${SELF_TEST_LOCAL:-0}" -eq 0 ]; then
        box_run "grep -qiE '$CLEAN_CLAIM_PATTERN' \"$path\" && echo yes || echo no" | grep -q '^yes$'
    else
        grep -qiE "$CLEAN_CLAIM_PATTERN" "$path" 2>/dev/null
    fi
}

log_lines_in() {
    local path="$1"
    if [ "${SELF_TEST_LOCAL:-0}" -eq 0 ]; then
        box_run "wc -l < \"$path\" 2>/dev/null | tr -d ' ' || echo 0"
    else
        wc -l < "$path" 2>/dev/null | tr -d ' ' || echo 0
    fi
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "cannot reach box ${OSTLER_BOX_HOST:-(local)} over ssh; install log not read"
    fi

    local lines
    lines="$(log_lines_in "$LOG_PATH")"
    lines="${lines:-0}"

    if [ "$lines" -eq 0 ]; then
        probe_cannot_run "no readable install log at $LOG_PATH (0 lines). The real path is \$HOME/.ostler/logs/install.log per install.sh:962; \$HOME/Documents/Ostler/logs is NOT it"
    fi

    probe_examined "$lines" "lines of $LOG_PATH"

    local errs
    errs="$(count_errors_in "$LOG_PATH")"
    errs="${errs:-0}"
    probe_note "errors counted independently: $errs"

    if claims_clean_in "$LOG_PATH"; then
        probe_note "log contains a clean-claim ('no errors detected' or similar)"
        if [ "$errs" -gt 0 ]; then
            probe_fail "installer claimed a clean run while its own log carries $errs error lines across $lines lines (task #270). The summary is not a result."
        fi
        probe_pass "installer claimed clean and the log agrees: 0 error lines in $lines"
    fi

    probe_note "log contains no clean-claim"
    probe_pass "no false clean-claim; $errs error lines in $lines are reported honestly or not summarised at all"
}

self_test() {
    # NEGATIVE CONTROL: a synthetic log that carries BOTH real errors AND a
    # closing clean-claim -- exactly the #270 shape. The probe must fail on it.
    local fixture
    fixture="$(mktemp -d)"
    trap 'rm -rf "$fixture"' EXIT
    SELF_TEST_LOCAL=1

    local bad="$fixture/install.log"
    cat > "$bad" <<'LOG'
2026-01-01 00:00:01 - INFO - starting
2026-01-01 00:00:02 - ERROR - Error parsing /example/path/a.json: 'str' object has no attribute 'get'
2026-01-01 00:00:03 - ERROR - Error parsing /example/path/b.json: 'str' object has no attribute 'get'
2026-01-01 00:00:04 - INFO - continuing
install.sh: line 999: convert: command not found
2026-01-01 00:00:05 - INFO - Install complete: no errors detected
LOG

    local lines errs
    lines="$(log_lines_in "$bad")"
    errs="$(count_errors_in "$bad")"
    probe_examined "$lines" "fixture log lines (negative control)"
    probe_note "fixture holds 3 planted errors and one clean-claim"

    if [ "$errs" -ne 3 ]; then
        probe_fail "counter found $errs of 3 planted errors -- the counter is wrong, so no verdict from this probe can be trusted"
    fi

    if ! claims_clean_in "$bad"; then
        probe_pass "NEGATIVE CONTROL DID NOT FIRE: clean-claim detector missed 'no errors detected'. This probe cannot detect task #270."
    fi

    # And it must NOT see a clean-claim in an honest log.
    local good="$fixture/honest.log"
    printf 'INFO starting\nERROR something broke\nINFO finished with 1 error, see above\n' > "$good"
    if claims_clean_in "$good"; then
        probe_pass "NEGATIVE CONTROL OVER-FIRED: clean-claim detector matched an honest log that reports its error. It would fail every truthful install."
    fi

    probe_fail "negative control behaved correctly (caught the false clean-claim, ignored the honest summary)"
}

probe_main "$@"
