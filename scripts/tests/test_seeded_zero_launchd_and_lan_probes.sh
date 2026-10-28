#!/bin/bash
# scripts/tests/test_seeded_zero_launchd_and_lan_probes.sh
#
# Pins four walk-probe decisions (harness119):
#   1. source_status_artefact_is_served: a source the walk SEEDED that reads
#      0 / no_data is FAIL (macOS 27 can deny an app-group read silently, and 0
#      rows would otherwise read as "no data"); the same body unseeded PASSes.
#      Driven END TO END through run_probe, with the Doctor body served from a
#      file:// URL and the Safari seed marker in a temp HOME.
#   2. ostler_launchd_jobs_loaded_and_exit_clean: launchctl print readings.
#   3. gateway_not_exposed_on_lan: LAN readings with the 8443/health control.
#   4. install_log_error_lines: every level=error / Command failed line printed
#      with its count, driven end to end against fixture logs.
# Plus one mutant per probe: break the decision and the self-test must go green
# (its negative control stops firing), which is the proof it drives the verdict.
# Synthetic data only. Never calls real launchctl or curl against a box.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
P="$ROOT/scripts/box_walk_probes"
fails=0
ok()  { printf 'ok    %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT

# ── 1. source_status, end to end ────────────────────────────────────────────
body() {  # body <apple_notes status> <apple_notes count> <browsing count>
    local i b='{"sources": ['
    b="${b}{\"source\":\"apple_notes\",\"status\":\"$1\",\"item_count\":$2},"
    b="${b}{\"source\":\"browsing\",\"status\":\"ok\",\"item_count\":$3},"
    for i in 3 4 5 6 7 8 9 10 11 12 13; do b="${b}{\"source\":\"s$i\",\"status\":\"ok\",\"item_count\":2},"; done
    printf '%s]}' "${b%,}"
}
ss_run() {  # ss_run <want rc> <label> <body> <seeded env> <safari marker or ->
    local h d rc
    h="$W/home.$RANDOM"; d="$W/doc.$RANDOM"; mkdir -p "$h" "$d/api/v1"
    printf '%s' "$3" > "$d/api/v1/sources"
    [ "$5" != "-" ] && printf '%s\n' "$5" > "$h/.walk-safari-seed-run"
    HOME="$h" OSTLER_BOX_HOST= OSTLER_DOCTOR_URL="file://$d" OSTLER_WALK_SEEDED_SOURCES="$4" \
        /bin/bash "$P/probes/source_status_artefact_is_served.sh" > "$W/out" 2>&1
    rc=$?
    if [ "$rc" -eq "$1" ]; then ok "source_status: $2 (rc=$rc)"; else bad "source_status: $2 (rc=$rc, want $1)"; sed 's/^/      /' "$W/out"; fi
}
ss_run 1 "seeded apple_notes reading no_data/0 is FAIL"        "$(body no_data 0 5)" apple_notes -
ss_run 1 "Safari seed planted, browsing reading 0 is FAIL"     "$(body ok 3 0)"      ""          "planted(visits=40)"
ss_run 0 "UNSEEDED apple_notes at no_data/0 stays PASS"        "$(body no_data 0 5)" ""          -
ss_run 0 "seeded apple_notes with a real count is PASS"        "$(body ok 7 5)"      apple_notes "planted(visits=40)"

# ── 4. install_log_error_lines, end to end against a fixture log ──────────
il_run() {  # il_run <label> <log file> <scope file or -> <want rc> <must-contain...>
    local label="$1" log="$2" scope="$3" want="$4" rc; shift 4
    if [ "$scope" = "-" ]; then
        HOME="$W" OSTLER_BOX_HOST= OSTLER_INSTALL_LOG="$log" /bin/bash "$P/probes/install_log_error_lines.sh" > "$W/out" 2>&1
    else
        HOME="$W" OSTLER_BOX_HOST= OSTLER_INSTALL_LOG="$log" OSTLER_PROMOTE_SCOPE_FILE="$scope" /bin/bash "$P/probes/install_log_error_lines.sh" > "$W/out" 2>&1
    fi
    rc=$?
    [ "$rc" -eq "$want" ] || { bad "install_log: $label (rc=$rc, want $want)"; sed 's/^/      /' "$W/out"; return; }
    for m in "$@"; do grep -F -q -- "$m" "$W/out" || { bad "install_log: $label: missing '$m'"; sed 's/^/      /' "$W/out"; return; }; done
    ok "install_log: $label (rc=$rc)"
}
printf 'step one\n#OSTLER LOG level=info msg=ok\n#OSTLER LOG level=error msg=hydrate failed rc=2\nDONE errors=0\n[x] Command failed inside a subshell at line 9: false\n' > "$W/two.log"
printf 'step one\n#OSTLER LOG level=info msg=ok\nDONE errors=0\n' > "$W/clean.log"
printf 'install_log_error_lines\tblocking\tCM051\ttest\n' > "$W/scope_blocking.tsv"
il_run "2 error lines print both, count=2 (advisory row: ADVISORY, rc 0)" "$W/two.log" - 0 "3:#OSTLER LOG level=error msg=hydrate failed" "5:[x] Command failed inside a subshell" "count=2" "VERDICT: ADVISORY"
il_run "2 error lines under a blocking row are FAIL" "$W/two.log" "$W/scope_blocking.tsv" 1 "count=2" "VERDICT: FAIL"
il_run "clean log prints count=0 with examined: install.log" "$W/clean.log" - 0 "count=0" "examined: install.log (3 lines)" "VERDICT: PASS"
il_run "absent log is CANNOT-RUN, never count=0" "$W/nope.log" - 78 "CANNOT-RUN"

# ── 2 + 3. self-tests must go red (rc 1: every negative control fired) ──────
for pr in source_status_artefact_is_served ostler_launchd_jobs_loaded_and_exit_clean gateway_not_exposed_on_lan install_log_error_lines; do
    /bin/bash "$P/probes/$pr.sh" --self-test > "$W/out" 2>&1; rc=$?
    if [ "$rc" -eq 1 ]; then ok "$pr --self-test rc=1"; else bad "$pr --self-test rc=$rc, want 1"; sed 's/^/      /' "$W/out"; fi
done

# ── mutants: break the decision, the self-test must stop going red ─────────
mutant() {  # mutant <probe> <perl substitution> <label>
    local m="$W/mut.$RANDOM"; mkdir -p "$m"; cp -R "$P/." "$m/"
    perl -0pi -e "$2" "$m/probes/$1.sh"
    if cmp -s "$P/probes/$1.sh" "$m/probes/$1.sh"; then bad "mutant did not apply: $3"; return; fi
    /bin/bash "$m/probes/$1.sh" --self-test > "$W/out" 2>&1; rc=$?
    if [ "$rc" -eq 0 ]; then ok "mutant caught: $3"; else bad "mutant NOT caught (rc=$rc): $3"; fi
}
mutant source_status_artefact_is_served 's/^if zero:$/if False:/m' "seeded-but-0 no longer fails"
mutant ostler_launchd_jobs_loaded_and_exit_clean 's/v="NOT-LOADED"; bad\+\+/v="NOT-LOADED"/' "an unloaded label no longer fails"
mutant install_log_error_lines 's/counted=\$\(\(counted \+ 1\)\)/counted=\$counted/' "an error line is printed but not counted"
mutant gateway_not_exposed_on_lan 's/^        7\) : ;;$/        7|0) : ;;/m' "a gateway answering on the LAN is read as refused"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
