#!/usr/bin/env bash
# probes/install_log_error_lines.sh
# ============================================================================
# QUESTION: which `level=error` and `Command failed` lines does the box's
#           install.log carry, and how many are not on the reviewed allowlist?
#
# WHY. The install's closing "DONE errors=N" counter misses errors raised inside
# subshells (lib/progress_emitter.sh, the err() -> gui_log level=error funnel
# counts in the parent shell only), so "DONE errors=0" can sit beside real
# errors in the same log. This probe does not trust the counter: it prints
# EVERY matching line with its line number, and the count.
#
# SCOPE: ADVISORY for its first cut (a new row expires after one cut), then
# BLOCKING against the reviewed allowlist install_log_error_allowlist.tsv (one
# ERE per line; a line matching one is printed as allowlisted and not counted).
#
# A zero is only reported as a look: "examined: install.log (<n> lines)". An
# absent or empty log is CANNOT-RUN, never count=0.
#
# macOS bash 3.2 + BSD userland. British English; no em dashes.
# ============================================================================

set -uo pipefail
HERE_PROBE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${HERE_PROBE}/../lib/probe.sh"

PROBE_NAME="install_log_error_lines"
PROBE_QUESTION="which level=error / Command failed lines does install.log carry (the DONE errors= counter misses subshell errors)?"

LOG_PATH="${OSTLER_INSTALL_LOG:-\$HOME/.ostler/logs/install.log}"
ALLOWLIST="${OSTLER_INSTALL_ERROR_ALLOWLIST:-${HERE_PROBE}/../install_log_error_allowlist.tsv}"

# adjudicate <box output> : box output is "LINES <n>" then grep -n matches.
# Prints the report and ONE final line: PASS|FAIL|CANNOT_RUN <text>.
adjudicate() {
    local out="$1" total hits allowed=0 counted=0 line pat ok
    total="$(printf '%s\n' "$out" | awk '$1=="LINES"{print $2; exit}')"
    case "$total" in ''|*[!0-9]*|0)
        echo "CANNOT_RUN no readable install log at ${LOG_PATH} (lines=${total:-none}); nothing was examined, so there is no count"; return ;;
    esac
    hits="$(printf '%s\n' "$out" | awk '$1!="LINES" && NF')"
    printf '  examined: install.log (%s lines)\n' "$total"
    if [ -n "$hits" ]; then
        while IFS= read -r line; do
            ok=""
            if [ -r "$ALLOWLIST" ]; then
                while IFS= read -r pat; do
                    case "$pat" in ''|'#'*) continue ;; esac
                    if grep -E -q -- "$pat" <<< "$line" 2>/dev/null; then ok=1; break; fi
                done < "$ALLOWLIST"
            fi
            if [ -n "$ok" ]; then
                allowed=$((allowed + 1)); printf '    allowlisted  %s\n' "$(printf '%s' "$line" | cut -c1-300)"
            else
                counted=$((counted + 1)); printf '    ERROR        %s\n' "$(printf '%s' "$line" | cut -c1-300)"
            fi
        done <<< "$hits"
    fi
    printf '  count=%d (allowlisted %d)\n' "$counted" "$allowed"
    if [ "$counted" -gt 0 ]; then
        echo "FAIL install.log carries ${counted} level=error / Command failed line(s) not on the reviewed allowlist (examined ${total} lines); the DONE errors= counter is not evidence of a clean install"
    else
        echo "PASS count=0 level=error / Command failed lines outside the allowlist; examined: install.log (${total} lines)"
    fi
}

_decide() {
    local v last token
    v="$(adjudicate "$1")"
    printf '%s\n' "$v" | sed '$d'
    last="$(printf '%s\n' "$v" | tail -n 1)"
    token="${last%% *}"
    probe_examined "$(printf '%s\n' "$1" | awk '$1=="LINES"{print $2+0; exit}')" "lines of install.log"
    case "$token" in
        PASS)       probe_pass "${last#* }" ;;
        FAIL)       probe_fail_or_advisory "${last#* }" ;;
        CANNOT_RUN) probe_cannot_run "${last#* }" ;;
        *)          probe_fail "adjudicator returned an unrecognised line: ${last}" ;;
    esac
}

run_probe() {
    if ! box_reachable; then
        probe_cannot_run "the box (${OSTLER_BOX_HOST:-local}) did not answer over ssh; install.log not read"
    fi
    _decide "$(box_run "f=${LOG_PATH}; if [ -r \"\$f\" ]; then printf 'LINES %s\n' \"\$(wc -l < \"\$f\" | tr -d ' ')\"; grep -n -E 'level=error|Command failed' \"\$f\"; else echo 'LINES 0'; fi")"
}

self_test() {
    probe_examined 3 "synthetic install.log readings (negative control)"
    local two clean
    two="$(adjudicate "LINES 40
12:#OSTLER LOG level=error msg=hydrate failed
31:[x] Command failed inside a subshell at line 9: false")"
    case "$two" in *count=2*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: 2 error lines did not count=2." ;; esac
    case "$(printf '%s\n' "$two" | tail -n 1)" in FAIL*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: 2 error lines were not a red." ;; esac
    clean="$(adjudicate "LINES 40")"
    case "$clean" in *"count=0"*"examined: install.log (40 lines)"*) : ;; *) probe_pass "NEGATIVE CONTROL OVER-FIRED: a clean 40-line log was not PASS count=0 with its examined line." ;; esac
    case "$(adjudicate "LINES 0" | tail -n 1)" in CANNOT_RUN*) : ;; *) probe_pass "NEGATIVE CONTROL DID NOT FIRE: an absent log read as count=0." ;; esac
    probe_fail "negative control behaved correctly on 3 readings (2 error lines count=2 and red; clean log count=0 with examined line; absent log CANNOT-RUN)"
}

probe_main "$@"
