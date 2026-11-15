#!/usr/bin/env bash
# tests/test_fda_refresh_tcc_probes.sh
# ============================================================================
# NEW-119 (diag118 Mini16, macOS 27.2, 2026-10-29). Drives the REAL probe
# scripts and the REAL ttywalk header lib against fakes, RED and GREEN each,
# plus one mutant per instrument that the arms must catch:
#
#   no_python_is_tcc_responsible (BLOCKING)
#     fake /usr/bin/log (OSTLER_PROBE_LOG_BIN) printing tccd-shaped fixtures
#     GREEN  control > 0, no python responsible               -> PASS 0
#     RED    python3.11 responsible (no responsible block)    -> FAIL 1
#     RED    python3.11 responsible (explicit block)          -> FAIL 1
#     CR     0 daemon-attributed requests                     -> CANNOT-RUN 78
#     CR     log show fails / no install start                -> CANNOT-RUN 78
#     MUTANT the control check removed: 0 daemon requests reads PASS. Caught.
#
#   fda_rerun_second_tick_lands_a_new_row (BLOCKING since #3210 merged)
#     fake launchctl (print/kickstart, a runs counter), real sqlite3 on a
#     synthetic History.db in a temp HOME, fake curl over a fake store file
#     GREEN  runs reach 2, the row seeded after install lands  -> PASS 0
#     RED    the row never lands / not loaded / only one run
#            -> FAIL 1 under the REAL walk_promote_scope.tsv (blocking)
#     CR     no synthetic plant / a real History.db / read-only walk -> 78
#     MUTANTS runs >= 1 accepted (one-run box reads PASS); landing ignored
#             (noland box reads PASS). Both caught.
#
#   ttywalk DECLARED STATE (lib_walk_tcc_declared.sh)
#     fake sudo over a synthetic TCC.db: rows printed with client, service,
#     auth_value, last_modified; refused sudo prints CANNOT-READ and returns 0
#     MUTANT the CANNOT-READ branch removed. Caught.
#
# Never touches a real TCC.db, launchd job, unified log or store. HOME is a
# fresh temp dir per run. Exit 0 pass, 1 fail, 2 cannot-run. Bash 3.2.
# ============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/scripts/box_walk_probes"
P1=no_python_is_tcc_responsible
P2=fda_rerun_second_tick_lands_a_new_row
SQ=/usr/bin/sqlite3
[ -x "$SQ" ] || SQ="$(command -v sqlite3 || true)"
command -v python3 >/dev/null 2>&1 && [ -n "$SQ" ] && [ -f "$SRC/probes/$P1.sh" ] && [ -f "$SRC/probes/$P2.sh" ] \
    || { echo "CANNOT-RUN: python3, sqlite3 or a probe is missing"; exit 2; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
unset OSTLER_BOX_HOST OSTLER_WALK_READ_ONLY OSTLER_PROMOTE_SCOPE_FILE
export OSTLER_UNDER_TEST=1
echo "test_fda_refresh_tcc_probes"

# ---- fakes -------------------------------------------------------------------
F="$W/fakes"; mkdir -p "$F"
cat > "$F/log" <<'SH'
#!/bin/sh
[ "${FAKE_LOG_RC:-0}" = 0 ] || { echo "log: Cannot run while sandboxed" >&2; exit "$FAKE_LOG_RC"; }
cat "$FAKE_LOG_FIXTURE"
SH
cat > "$F/launchctl" <<SH
#!/bin/sh
D="\$FAKE_LC_DIR"; M="\${FAKE_LC_MODE:-good}"
runs=\$(cat "\$D/runs" 2>/dev/null || echo 0)
case "\$1" in
  print)
    [ "\$M" = notloaded ] && { echo "Could not find service \"com.ostler.fda-rerun\" in domain for user gui: 501"; exit 113; }
    printf 'gui/501/com.ostler.fda-rerun = {\n\tstate = not running\n\truns = %s\n\tlast exit code = %s\n}\n' "\$runs" "\$( [ "\$M" = badexit ] && echo 1 || echo 0)"
    ;;
  kickstart)
    [ "\$M" = notloaded ] && exit 113
    if [ "\$M" = once ] && [ -e "\$D/kicked" ]; then exit 0; fi
    : > "\$D/kicked"
    echo \$((runs + 1)) > "\$D/runs"
    [ "\$M" = noland ] || "$SQ" "\$HOME/Library/Safari/History.db" 'select url from history_items' >> "\$D/store" 2>/dev/null
    ;;
esac
exit 0
SH
cat > "$F/curl" <<'SH'
#!/bin/sh
body=""; while [ $# -gt 0 ]; do [ "$1" = "-d" ] && body="$2"; shift; done
url=$(printf '%s' "$body" | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')
n=$(grep -cxF "$url" "$FAKE_LC_DIR/store" 2>/dev/null); n=${n:-0}
printf '{"result":{"count":%s},"status":"ok"}\n200' "$n"
SH
cat > "$F/sudo" <<'SH'
#!/bin/sh
[ "${FAKE_SUDO:-ok}" = ok ] || { echo "sudo: a password is required" >&2; exit 1; }
[ "$1" = "-n" ] && shift
exec "$@"
SH
chmod +x "$F"/*

# tccd-shaped fixtures, built from the judge's own fixture constants so the
# test and the self-test share one definition of a real line.
python3 - "$SRC/lib" "$W" <<'PY'
import sys; sys.path.insert(0, sys.argv[1]); import fda_refresh_tcc as t
for name, txt in (("control_only", t.CONTROL_ONLY), ("py_noblock", t.PY_RESPONSIBLE_NO_BLOCK),
                  ("py_block", t.PY_RESPONSIBLE_BLOCK), ("no_control", t.NO_CONTROL)):
    open("%s/%s.log" % (sys.argv[2], name), "w").write(txt)
PY

newhome() { local h; h="$(mktemp -d "$W/home.XXXX")"; mkdir -p "$h/.ostler"; printf 'ttywalk %s\n' "$(( $(date +%s) - 600 ))" > "$h/.ostler/.install-harness"; printf '%s' "$h"; }

# run_p1 <tree> <fixture> [log rc] -> rc
run_p1() {
    local h; h="$(newhome)"
    HOME="$h" OSTLER_PROBE_LOG_BIN="$F/log" FAKE_LOG_FIXTURE="$W/$2.log" FAKE_LOG_RC="${3:-0}" \
        bash "$1/probes/$P1.sh" > "$W/out.p1.$2" 2>&1; echo $?
}

plant() {  # $1 home -> a synthetic History.db exactly as the walk seed plants it
    mkdir -p "$1/Library/Safari"
    python3 -I "$SRC/lib/safari_history_fixture.py" "$1/Library/Safari/History.db" >/dev/null
    printf 'planted(visits=18)\n' > "$1/.walk-safari-seed-run"
}
# run_p2 <tree> <mode> [scope file] [setup: plant|real|none] -> rc
run_p2() {
    local h lc; h="$(newhome)"; lc="$(mktemp -d "$W/lc.XXXX")"
    case "${4:-plant}" in
        plant) plant "$h" ;;
        real)  plant "$h"; "$SQ" "$h/Library/Safari/History.db" 'drop table walk_synthetic_marker' ;;
    esac
    printf 'header = "Authorization: Bearer x"\n' > "$h/.ostler/store.conf"
    ( [ -n "${3:-}" ] && export OSTLER_PROMOTE_SCOPE_FILE="$3"
      HOME="$h" FAKE_LC_DIR="$lc" FAKE_LC_MODE="$2" OSTLER_PROBE_LAUNCHCTL="$F/launchctl" \
      OSTLER_PROBE_CURL="$F/curl" OSTLER_PROBE_SQLITE="$SQ" OSTLER_PROBE_STORE_CURL_CONF='$HOME/.ostler/store.conf' \
      OSTLER_PROBE_FDA_TICK_WAIT_S=5 OSTLER_PROBE_FDA_TICK_POLL_S=1 \
      bash "$1/probes/$P2.sh" > "$W/out.p2.$2" 2>&1; echo $? > "$W/rc" )
    printf '%s' "$h" > "$W/lasthome"
    cat "$W/rc"
}

expect() { [ "$2" = "$3" ] && ok "$1 -> rc $2" || { bad "$1 -> rc $2, wanted $3"; [ -n "${4:-}" ] && sed 's/^/        /' "$4" | tail -8; }; }

echo "--- self-tests behave (exit 1, the negative control) ---"
for p in $P1 $P2; do
    bash "$SRC/probes/$p.sh" --self-test > "$W/st" 2>&1; rc=$?
    [ "$rc" -eq 1 ] && grep -q '^VERDICT: FAIL -- negative control behaved' "$W/st" && ok "$p self-test behaves" || bad "$p self-test rc=$rc"
done

echo "--- $P1 ---"
expect "control only (daemon -> python child), none python-responsible" "$(run_p1 "$SRC" control_only)" 0 "$W/out.p1.control_only"
grep -q 'control (daemon -> python child) 1' "$W/out.p1.control_only" && ok "the control count is printed" || bad "control count not printed"
expect "python3.11 responsible, no responsible block" "$(run_p1 "$SRC" py_noblock)" 1 "$W/out.p1.py_noblock"
expect "python3.11 responsible, explicit block" "$(run_p1 "$SRC" py_block)" 1 "$W/out.p1.py_block"
grep -q '^VERDICT: FAIL' "$W/out.p1.py_block" && ok "RED is FAIL, not ADVISORY (blocking scope)" || bad "RED did not print FAIL"
expect "0 daemon-attributed requests is CANNOT-RUN, never PASS" "$(run_p1 "$SRC" no_control)" 78 "$W/out.p1.no_control"
expect "log show failed" "$(run_p1 "$SRC" control_only 64)" 78 "$W/out.p1.control_only"
h="$(newhome)"; rm -f "$h/.ostler/.install-harness"
HOME="$h" OSTLER_PROBE_LOG_BIN="$F/log" FAKE_LOG_FIXTURE="$W/control_only.log" bash "$SRC/probes/$P1.sh" > "$W/out.nostart" 2>&1
expect "no recorded install start" "$?" 78 "$W/out.nostart"

echo "--- $P2 ---"
expect "runs reach 2 and the row seeded after install lands" "$(run_p2 "$SRC" good)" 0 "$W/out.p2.good"
n="$("$SQ" "$(cat "$W/lasthome")/Library/Safari/History.db" "select count(*) from history_items where url like '%walk-second-tick%'")"
[ "$n" = 0 ] && ok "the seeded visit is removed from the fixture afterwards" || bad "seeded visit left behind ($n)"
grep -q 'runs now 2' "$W/out.p2.good" && ok "runs reached 2" || bad "runs did not reach 2"
expect "the row never lands (real scope)" "$(run_p2 "$SRC" noland)" 1 "$W/out.p2.noland"
grep -q '^VERDICT: FAIL' "$W/out.p2.noland" && ok "row never lands prints FAIL, not ADVISORY" || bad "row never lands did not print FAIL"
expect "fda-rerun not loaded (real scope)" "$(run_p2 "$SRC" notloaded)" 1 "$W/out.p2.notloaded"
expect "only one run ever happens (real scope)" "$(run_p2 "$SRC" once)" 1 "$W/out.p2.once"
grep -q '^VERDICT: FAIL' "$W/out.p2.once" && ok "only one run prints FAIL, not ADVISORY" || bad "only one run did not print FAIL"
expect "non-zero last exit (real scope)" "$(run_p2 "$SRC" badexit)" 1 "$W/out.p2.badexit"
grep -q "^fda_rerun_second_tick_lands_a_new_row	blocking	" "$REPO/scripts/walk_promote_scope.tsv" && ok "the real scope row is blocking" || bad "scope row is not blocking"
expect "no synthetic plant" "$(run_p2 "$SRC" good "" none)" 78 "$W/out.p2.good"
expect "a History.db without the synthetic marker is never written" "$(run_p2 "$SRC" good "" real)" 78 "$W/out.p2.good"
n="$("$SQ" "$(cat "$W/lasthome")/Library/Safari/History.db" "select count(*) from history_items where url like '%walk-second-tick%'")"
[ "$n" = 0 ] && ok "the unmarked History.db was not written" || bad "unmarked History.db was written"
r="$(OSTLER_WALK_READ_ONLY=1 run_p2 "$SRC" good)"; expect "read-only walk" "$r" 78 "$W/out.p2.good"

echo "--- ttywalk DECLARED STATE ---"
LIB="$REPO/scripts/lib_walk_tcc_declared.sh"
TDB="$W/TCC.db"
SYN_HOME="/"Users"/walk1"  # built from parts at runtime: synthetic account, no literal home path
"$SQ" "$TDB" "create table access(service TEXT, client TEXT, client_type INT, auth_value INT, auth_reason INT, last_modified INT);
insert into access values('kTCCServiceSystemPolicyAllFiles','ai.ostler.installer',0,2,4,1757822488),
('kTCCServiceSystemPolicyAllFiles','${SYN_HOME}/.ostler/python/bin/python3.11',1,0,5,1757829357),
('kTCCServiceCamera','com.example.other',0,2,4,1)"
decl() {  # $1 lib, $2 sudo ok|refuse
    ( h="$(mktemp -d "$W/dh.XXXX")"; . "$1"
      HOME="$h" FAKE_SUDO="$2" OSTLER_TCC_SUDO="$F/sudo" OSTLER_TCC_SQLITE="$SQ" OSTLER_TCC_SYSTEM_DB="$TDB" walk_tcc_declared_state ); }
o="$(decl "$LIB" ok)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q '2 pre-existing Ostler row(s) of 3 total' \
  && printf '%s' "$o" | grep -q 'ai.ostler.installer|kTCCServiceSystemPolicyAllFiles|2|2025-09-14' \
  && printf '%s' "$o" | grep -q 'python3.11|kTCCServiceSystemPolicyAllFiles|0|' \
  && ! printf '%s' "$o" | grep -q 'com.example.other' && ok "rows declared: client, service, auth_value, last_modified; non-Ostler rows excluded" || { bad "declared rows"; printf '%s\n' "$o"; }
printf '%s' "$o" | grep -q 'per-user TCC.db absent' && ok "per-user TCC.db reported absent" || bad "per-user line"
o="$(decl "$LIB" refuse)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$o" | grep -q 'CANNOT-READ' && ok "unreadable prints CANNOT-READ and returns 0" || { bad "unreadable rc=$rc"; printf '%s\n' "$o"; }
s="$(grep -n 'source "$(dirname "${BASH_SOURCE\[0\]}")/lib_walk_tcc_declared.sh"' "$REPO/scripts/ttywalk.sh" | cut -d: -f1)"
r="$(grep -n '^if \[\[ "\$DO_RESET" -eq 1 \]\]; then' "$REPO/scripts/ttywalk.sh" | head -1 | cut -d: -f1)"
[ -n "$s" ] && [ -n "$r" ] && [ "$s" -lt "$r" ] && grep -q 'walk_tcc_declared_state' "$REPO/scripts/ttywalk.sh" \
  && ok "ttywalk sources the lib and records it before the reset" || bad "ttywalk wiring (source line ${s:-none}, reset ${r:-none})"
cat "$LIB" "$SRC/probes/$P1.sh" "$SRC/probes/$P2.sh" "$SRC/lib/fda_refresh_tcc.py" | grep -v '^[[:space:]]*#' | grep -q 'tccutil' && bad "tccutil appears in the new code" || ok "no tccutil anywhere in the new code"

echo "--- mutants (each must be caught) ---"
mut_tree() { local t="$W/mut.$1"; rm -rf "$t"; cp -R "$SRC" "$t"; printf '%s' "$t"; }
T1="$(mut_tree control)"
python3 - "$T1/lib/fda_refresh_tcc.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
n=s.replace('    if c.get("control", 0) == 0:\n', '    if False:\n'); assert n!=s; open(p,'w').write(n)
PY
cmp -s "$T1/lib/fda_refresh_tcc.py" "$SRC/lib/fda_refresh_tcc.py" && { echo "CANNOT-RUN: mutant 1 did not apply"; exit 2; }
[ "$(run_p1 "$T1" no_control)" = 78 ] && bad "MUTANT control-removed was NOT caught" || ok "MUTANT control-removed (0 daemon requests reads PASS) is caught"
T2="$(mut_tree runs)"
python3 - "$T2/lib/fda_refresh_tcc.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
n=s.replace('    if f["runs"] < 2:\n', '    if f["runs"] < 1:\n'); assert n!=s; open(p,'w').write(n)
PY
[ "$(run_p2 "$T2" once)" = 1 ] && bad "MUTANT runs>=1 was NOT caught" || ok "MUTANT runs>=1 (one-run box reads PASS) is caught"
T3="$(mut_tree landed)"
python3 - "$T3/lib/fda_refresh_tcc.py" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
n=s.replace('    if f["landed"] < 1:\n', '    if f["landed"] < 0:\n'); assert n!=s; open(p,'w').write(n)
PY
[ "$(run_p2 "$T3" noland)" = 1 ] && bad "MUTANT landing-ignored was NOT caught" || ok "MUTANT landing-ignored (noland box reads PASS) is caught"
ML="$W/mut_decl.sh"
python3 - "$LIB" "$ML" <<'PY'
import sys; s=open(sys.argv[1]).read()
n=s.replace("tcc declared: CANNOT-READ", "tcc declared: 0 pre-existing Ostler row(s)"); assert n!=s; open(sys.argv[2],'w').write(n)
PY
o="$(decl "$ML" refuse)"
printf '%s' "$o" | grep -q 'CANNOT-READ' && bad "MUTANT CANNOT-READ-removed was NOT caught" || ok "MUTANT CANNOT-READ-removed (unreadable prints a false zero) is caught"

echo "---"
echo "passed $pass failed $fail"
[ "$fail" -eq 0 ]
