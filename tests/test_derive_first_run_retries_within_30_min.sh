#!/usr/bin/env bash
#
# tests/test_derive_first_run_retries_within_30_min.sh
#
# THE DEFECT. com.ostler.derive-preferences is RunAtLoad=false with a 6 hour
# StartInterval. The installer kicks it once after import; under first-run load
# that pass comes back empty/degraded (the walk saw /api/v1/preferences/derived
# 200, degraded, items=0) and the next try was up to 6 HOURS away.
#
# WHAT THIS RUNS. The REAL _install_derive_preferences_agent is lifted out of
# install.sh, run in a sandbox HOME (launchctl stubbed), and the wrapper it
# GENERATES is executed. Time is moved by ageing the cadence state file, not by
# a fake clock. The runner is a stub that writes outcome=empty or written.
#
#   1  the plist ticks every <= 3600s (1800), and carries the 6h period.
#   2  empty first pass: not settled, attempts=1.
#   3  NEGATIVE: an immediate second tick does NOT run the runner.
#   4  RETRY: 31 min later the next tick runs the runner again.
#   5  a pass that WRITES settles; 31 min later does NOT run; 6h+ later runs.
#   6  six empty passes settle (bounded), then 31 min does NOT run.
#   7  the installer's kick mark bypasses the cadence once and is consumed.
#   8  the cadence is a file under state/: a fresh process (a reboot) and a
#      re-run of the installer function (the Sparkle upgrade path) keep it.
#   MUTANTS (each must turn this test RED): M1 the cadence never waits (no
#   gate), M2 nothing ever settles, M3 a written pass does not settle.
#
# INSTALL_SH may point at another copy. Exit 0 pass, 1 fail, 2 cannot-run.
# Bash 3.2 portable. Synthetic only.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
INSTALL_SH="${INSTALL_SH:-${REPO}/install.sh}"
[ -r "$INSTALL_SH" ] || { echo "CANNOT-RUN: $INSTALL_SH unreadable"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "CANNOT-RUN: no python3"; exit 2; }
SANDBOX="$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd)/derive-retry.XXXXXX")" || { echo "CANNOT-RUN: mktemp"; exit 2; }
trap 'rm -rf "$SANDBOX"' EXIT

BIN="${SANDBOX}/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "${BIN}/launchctl"; chmod +x "${BIN}/launchctl"

lift_function() { # file name -> stdout
    local f="$1" name="$2" start end
    start="$(grep -nE "^${name}\(\) \{" "$f" | head -1 | cut -d: -f1)"
    [ -n "$start" ] || return 1
    for end in $(awk -v s="$start" 'NR > s && /^\}/ { print NR }' "$f"); do
        sed -n "${start},${end}p" "$f" > "${SANDBOX}/lift.sh"
        if bash -n "${SANDBOX}/lift.sh" 2>/dev/null; then cat "${SANDBOX}/lift.sh"; return 0; fi
    done
    return 1
}

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); [ "${QUIET:-0}" = 1 ] || echo "  ok   $*"; }
bad() { FAIL=$((FAIL + 1)); [ "${QUIET:-0}" = 1 ] || echo "  FAIL $*"; }

new_box() { # agentfile name -> H O W
    H="${SANDBOX}/$2"; O="${H}/.ostler"; mkdir -p "$O/logs"
    (
        export HOME="$H" PATH="${BIN}:${PATH}"
        OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
        ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }
        . "$1"; _install_derive_preferences_agent
    ) >/dev/null 2>&1
    W="${O}/bin/ostler-derive-preferences-tick"; PL="${H}/Library/LaunchAgents/com.ostler.derive-preferences.plist"
    mkdir -p "${O}/services/cm019/.venv/bin"
    cat > "${O}/services/cm019/.venv/bin/python3" <<'EOF'
#!/bin/sh
[ "${1:-}" = "-c" ] && exit 0
echo "run" >> "${OSTLER_DIR}/runs.log"
exec /usr/bin/env python3 -c '
import json, os, time
n = 5 if os.path.exists(os.path.join(os.environ["OSTLER_DIR"], "WRITE")) else 0
p = os.path.join(os.environ["OSTLER_DIR"], "state", "derived-preferences.json")
rec = {"schema": 1, "last_run_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
       "outcome": "written" if n else "empty", "graph_node_count": n, "reason": ""}
open(p, "w").write(json.dumps(rec, indent=2, sort_keys=True) + "\n")
'
EOF
    chmod +x "${O}/services/cm019/.venv/bin/python3"
}
tick() { env HOME="$H" PATH="${BIN}:/usr/bin:/bin" OSTLER_DIR="$O" OSTLER_RESOURCE_GOVERNOR=0 OSTLER_INGEST_SLOT=0 \
    OSTLER_DERIVE_PERIOD_S=21600 /bin/bash "$W" >/dev/null 2>&1; }
runs() { [ -f "${O}/runs.log" ] && wc -l < "${O}/runs.log" | tr -d ' ' || echo 0; }
cad() { sed -n "s/^$1=//p" "${O}/state/derive-preferences.cadence" 2>/dev/null | tail -1; }
age() { # seconds: move last_pass_epoch back
    local f="${O}/state/derive-preferences.cadence" t
    t=$(( $(cad last_pass_epoch) - $1 ))
    sed "s/^last_pass_epoch=.*/last_pass_epoch=${t}/" "$f" > "$f.n" && mv "$f.n" "$f"
}
expect_runs() { # want label
    [ "$(runs)" = "$1" ] && ok "$2 (runner calls=$1)" || bad "$2 (wanted runner calls=$1, got $(runs))"
}

scenario() { # agentfile tag
    local A="$1" T="$2"
    new_box "$A" "${T}-a"
    grep -q '<integer>1800</integer>' "$PL" && grep -q 'OSTLER_DERIVE_PERIOD_S</key><string>21600<' "$PL" \
        && ok "1 plist ticks every 1800s and carries the 21600s period" || bad "1 plist StartInterval/period"
    tick
    [ "$(cad attempts)" = 1 ] && [ "$(cad settled)" = 0 ] && ok "2 empty first pass: attempts=1 settled=0" || bad "2 cadence after empty pass: attempts=$(cad attempts) settled=$(cad settled)"
    tick; expect_runs 1 "3 immediate second tick does not run (NEGATIVE)"
    age 1860; tick; expect_runs 2 "4 31 min later the retry runs"
    : > "${O}/WRITE"; age 1860; tick
    [ "$(cad settled)" = 1 ] && ok "5a a written pass settles" || bad "5a written pass did not settle"
    age 1860; tick; expect_runs 3 "5b settled: 31 min later does not run"
    age 21700; tick; expect_runs 4 "5c settled: 6h+ later runs"
    # 6 bounded: six empty passes settle
    new_box "$A" "${T}-b"; i=0
    while [ "$i" -lt 6 ]; do tick; age 1860; i=$((i + 1)); done
    [ "$(runs)" = 6 ] && [ "$(cad settled)" = 1 ] && ok "6a six empty passes ran and settled" || bad "6a runs=$(runs) settled=$(cad settled)"
    tick; expect_runs 6 "6b after settling, 31 min does not run"
    # 7 kick bypass
    : > "${O}/state/derive-preferences.kick"; tick
    [ "$(runs)" = 7 ] && [ ! -f "${O}/state/derive-preferences.kick" ] && ok "7 kick bypasses once and is consumed" || bad "7 kick: runs=$(runs)"
    # 8 survives reboot / upgrade (installer re-run keeps state)
    new_box "$A" "${T}-c"; tick
    ( export HOME="$H" PATH="${BIN}:${PATH}"; OSTLER_DIR="$O"; LOGS_DIR="${O}/logs"
      ok() { :; }; warn() { :; }; info() { :; }; _ks_bounded() { :; }; . "$A"; _install_derive_preferences_agent ) >/dev/null 2>&1
    tick; expect_runs 1 "8 after the installer re-ran (upgrade) the cadence state still gates"
}

lift_function "$INSTALL_SH" _install_derive_preferences_agent > "${SANDBOX}/agent.sh" \
    || { echo "CANNOT-RUN: could not lift _install_derive_preferences_agent"; exit 2; }
echo "REAL install.sh:"; scenario "${SANDBOX}/agent.sh" real
REAL_FAIL=$FAIL

# Mutants: edit the lifted function, require each to go RED.
mutant() { # name sed-expr
    sed "$2" "${SANDBOX}/agent.sh" > "${SANDBOX}/m.sh"
    if cmp -s "${SANDBOX}/agent.sh" "${SANDBOX}/m.sh"; then bad "$1 did not apply (mutant identical)"; return; fi
    local before=$FAIL; QUIET=1 scenario "${SANDBOX}/m.sh" "$1"; QUIET=0
    if [ "$FAIL" -gt "$before" ]; then FAIL=$before; ok "mutant $1 turns the test red"; else bad "mutant $1 SURVIVED"; fi
}
echo "Mutants:"
mutant M1 's/\[\[ \$((NOW - CAD_AT)) -ge \$((_wait - 120)) \]\] ||/true ||/'
mutant M2 's/\[\[ "\$(_jf outcome)" == written || "\$CAD_OK" == 1 || "\$n" -ge[^]]*\]\] && s=1;/:;/'
mutant M3 's/"\$(_jf outcome)" == written ||//'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
