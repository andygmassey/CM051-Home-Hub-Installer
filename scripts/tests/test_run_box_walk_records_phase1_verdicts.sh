#!/usr/bin/env bash
# run_box_walk.sh appends every verdict it reaches to $OSTLER_PHASE1_VERDICTS so
# the cut-manifest replay can take the verdict measured against the seed fixture
# instead of running the probe again after the forgets (v1.0.89, 2026-09-10:
# the replay re-ran assistant_answers_grounded after SEED-FORGET OK and read
# tool_found_nothing on stores it had just emptied).
#
# The runner is copied into a scratch tree whose probes/ holds four stubs, one
# per verdict word, so the real loop runs end to end against no box. Exit 0 on
# pass, 1 on a finding. Every arm names what it read.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${HERE}/../box_walk_probes"
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no scratch dir"; exit 78; }
trap 'rm -rf "$WORK"' EXIT
fails=0
bad() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
ok()  { printf '  ok    %s\n' "$*"; }

_stage() {   # $1 = tree name; copies the runner + lib, replaces probes/ with stubs
    local t="${WORK}/$1"
    cp -R "$SRC" "$t"
    rm -f "$t"/probes/*.sh
    _stub "$t" stub_pass 0  1 "PASS -- fine"
    _stub "$t" stub_fail 1  1 "FAIL -- known-bad"
    _stub "$t" stub_cant 78 1 "CANNOT-RUN -- no box"
    _stub "$t" stub_brok 0  0 "PASS -- but my negative control never fires"
    _stub "$t" assistant_answers_grounded 0 1 "PASS -- a stub wearing a seed-dependent name"
    printf '%s' "$t"
}
_stub() {    # tree name exit self_test_exit message
    printf '#!/usr/bin/env bash\n[ "${1:-}" = "--self-test" ] && exit %s\necho "VERDICT: %s"\nexit %s\n' \
        "$4" "$5" "$3" > "$1/probes/$2.sh"
    chmod +x "$1/probes/$2.sh"
}
_run() {     # tree verdict_file_or_empty -> runs the loop, output in $WORK/out.txt
    ( cd "$1" && OSTLER_PHASE1_VERDICTS="$2" OSTLER_BOX_HOST=fake.invalid \
        perl -e 'alarm 240; exec @ARGV' bash ./run_box_walk.sh ) > "${WORK}/out.txt" 2>&1
    return $?
}
_row() {     # file probe -> the LAST row for that probe, or empty
    awk -F'\t' -v p="$2" '$1 == p {r = $0} END {print r}' "$1"
}

printf -- '--- arm 1: the four verdict words reach the file, with reasons and the fixture column ---\n'
T="$(_stage t1)"; V="${WORK}/t1.tsv"
_run "$T" "$V"; rc=$?
[ -f "$V" ] || { bad "no verdict file was written (run_box_walk rc=${rc})"; cat "${WORK}/out.txt" | tail -n 20; exit 1; }
n=$(wc -l < "$V" | tr -d ' ')
[ "$n" -eq 5 ] && ok "5 rows for 5 stubs" || bad "expected 5 rows, read ${n}: $(tr '\n' '|' < "$V")"
for spec in "stub_pass|PASS|" "stub_fail|FAIL|known-bad" "stub_cant|CANNOT-RUN|no box" "stub_brok|BROKEN|negative control"; do
    p=${spec%%|*}; rest=${spec#*|}; w=${rest%%|*}; why=${rest#*|}
    row="$(_row "$V" "$p")"
    word="$(printf '%s' "$row" | cut -f2)"; when="$(printf '%s' "$row" | cut -f3)"; reason="$(printf '%s' "$row" | cut -f4)"
    [ "$word" = "$w" ] && ok "${p} -> ${w}" || bad "${p}: expected ${w}, row reads: ${row}"
    case "$when" in 20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) bad "${p}: utc column reads ${when}" ;; esac
    if [ -n "$why" ]; then
        case "$reason" in *"$why"*) ok "${p} reason carries '${why}'" ;; *) bad "${p}: reason column reads '${reason}', expected it to carry '${why}'" ;; esac
    fi
    fx="$(printf '%s' "$row" | cut -f5)"
    [ "$fx" = "live" ] && ok "${p} fixture column reads live" || bad "${p}: fixture column reads '${fx}', expected live"
done
fx="$(_row "$V" assistant_answers_grounded | cut -f5)"
[ "$fx" = "seed-fixture" ] && ok "assistant_answers_grounded fixture column reads seed-fixture (in SEED_DEPENDENT_PROBES)" || bad "assistant_answers_grounded: fixture column reads '${fx}', expected seed-fixture"

printf -- '--- arm 2: control, env unset writes nothing ---\n'
T="$(_stage t2)"
_run "$T" ""; rc=$?
if ls "$T"/*.tsv "${WORK}"/t2*.tsv >/dev/null 2>&1; then bad "a tsv appeared with the env unset"; else ok "no verdict file without the env (rc=${rc})"; fi

printf -- '--- arm 3: mutant control, the PASS write removed must lose the PASS row ---\n'
T="$(_stage t3)"; V="${WORK}/t3.tsv"
# Portable deletion: `sed -i ''` is BSD-only and on the GNU runner reads '' as the
# script and the pattern as a filename (measured 2026-09-10, run 34502389353).
mut=$(grep -cF '_record_verdict "$b" PASS ""' "$T/run_box_walk.sh")
[ "$mut" -eq 1 ] || bad "mutant anchor count ${mut}, expected 1"
grep -vF '_record_verdict "$b" PASS ""' "$T/run_box_walk.sh" > "$T/run_box_walk.sh.mut" && mv "$T/run_box_walk.sh.mut" "$T/run_box_walk.sh"
after=$(grep -cF '_record_verdict "$b" PASS ""' "$T/run_box_walk.sh")
[ "$after" -eq 0 ] && ok "mutant applied (anchor ${mut} -> ${after})" || bad "mutant did NOT apply (anchor still ${after}); a mutant that did not apply looks exactly like one that was not caught"
_run "$T" "$V"
if [ -n "$(_row "$V" stub_pass)" ]; then bad "mutant: PASS row still present, the arm 1 assertion is not reading the write"; else ok "mutant lost the PASS rows ($(wc -l < "$V" | tr -d ' ') rows left: $(cut -f1 "$V" | tr '\n' ' '))"; fi

printf '\n'
if [ "$fails" -eq 0 ]; then echo "PASS: run_box_walk.sh records phase 1 verdicts with the fixture column (3 arms)"; exit 0; fi
echo "FAIL: ${fails} finding(s)"; exit 1
