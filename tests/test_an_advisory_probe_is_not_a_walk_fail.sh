#!/usr/bin/env bash
# AN ADVISORY RESULT IS NOT A WALK FAIL (Lane 17 review, Andy).
#
# scripts/walk_promote_scope.tsv says a probe is `advisory`: its red is printed
# and signed off but does not refuse a promote. The walk's own tally and exit
# code disagreed: any probe red counted as FAIL and made the walk exit 1, so an
# advisory probe under its target made every walk unclean while its row said
# advisory. A probe now reads its own scope row (lib/probe.sh
# probe_fail_or_advisory); if advisory it prints `VERDICT: ADVISORY` and exits 0,
# and run_box_walk.sh tallies it on its own line.
#
# Arms (hermetic: the real runner and lib, fixture probes, a fixture scope file):
#   1 CONTROL    a probe that really FAILs (probe_fail) still exits 1
#   2 SUBJECT    advisory row, below threshold: rc 0, ADVISORY 1, FAIL 0, probe named
#   3 SAME PROBE with the row set to blocking: FAIL 1, rc 1
#   4 FAIL-CLOSED a missing scope file is blocking, not advisory
#   5 ADVISORY cannot hide a real FAIL beside it: rc 1
#   6 post_walk_qa.sh's parser still recovers the FAILED name from the output
# /bin/bash on purpose (cut host is bash 3.2). Exit 0 pass, 1 an arm failed, 2 cannot run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/box_walk_probes/run_box_walk.sh"
LIB="$REPO_ROOT/scripts/box_walk_probes/lib"
for f in "$RUNNER" "$LIB/probe.sh"; do [ -e "$f" ] || { echo "CANNOT-RUN: $f missing" >&2; exit 2; }; done
FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
TAB="$(printf '\t')"

_probe() { # dir name kind(advisory_red|hard_fail|ok)
    local body
    case "$3" in
        advisory_red) body='probe_fail_or_advisory "scored 12.5 percent against a target of 70"' ;;
        hard_fail)    body='probe_fail "a real defect"' ;;
        ok)           body='probe_pass "fine"' ;;
    esac
    cat > "$1/probes/$2.sh" <<EOT
#!/usr/bin/env bash
set -uo pipefail
. "\$(dirname "\${BASH_SOURCE[0]}")/../lib/probe.sh"
PROBE_NAME="$2"
PROBE_QUESTION="fixture"
run_probe() { probe_examined 1 "fixture thing"; $body; }
self_test() { probe_examined 1 "fixture thing"; probe_fail "negative control"; }
probe_main "\$@"
EOT
    chmod +x "$1/probes/$2.sh"
}
_suite() { # dir, then name:kind ...
    local d="$1"; shift
    rm -rf "$d"; mkdir -p "$d/probes" "$d/lib"
    cp "$RUNNER" "$d/run_box_walk.sh"; cp "$LIB"/*.sh "$d/lib/"
    printf '# register\n' > "$d/console_only_probes.tsv"
    local s; for s in "$@"; do _probe "$d" "${s%%:*}" "${s##*:}"; done
}
_run() { # dir, log, scope-file ; echoes rc
    local rc=0
    ( cd "$1" && OSTLER_PROMOTE_SCOPE_FILE="$3" /bin/bash ./run_box_walk.sh ) > "$2" 2>&1 || rc=$?
    echo "$rc"
}
num() { awk -v k="$2" '$1==k && NF==2 && $2 ~ /^[0-9]+$/ {print $2; exit}' "$1"; }

ADV="$WORK/adv.tsv"; BLK="$WORK/blk.tsv"
printf '# scope\nzz_score%sadvisory%sfixture%swhy\n' "$TAB" "$TAB" "$TAB" > "$ADV"
printf '# scope\nzz_score%sblocking%sfixture%swhy\n' "$TAB" "$TAB" "$TAB" > "$BLK"

_suite "$WORK/a1" "aa_hard:hard_fail"
RC="$(_run "$WORK/a1" "$WORK/a1.log" "$ADV")"
if [ "$RC" -eq 1 ] && [ "$(num "$WORK/a1.log" FAIL)" = "1" ]; then pass "(1) control: a real probe_fail still counts as FAIL and exits 1"
else fail "1-control" "rc=$RC fail=$(num "$WORK/a1.log" FAIL); the harness cannot show a red, so nothing below is trustworthy"; exit 1; fi

_suite "$WORK/a2" "aa_ok:ok" "zz_score:advisory_red"
RC="$(_run "$WORK/a2" "$WORK/a2.log" "$ADV")"
if [ "$RC" -eq 0 ] && [ "$(num "$WORK/a2.log" FAIL)" = "0" ] && [ "$(num "$WORK/a2.log" ADVISORY)" = "1" ] \
   && [ "$(grep -c 'VERDICT: ADVISORY' "$WORK/a2.log")" -ge 1 ] && [ "$(grep -c 'zz_score' "$WORK/a2.log")" -ge 2 ]; then
    pass "(2) advisory below threshold: walk rc 0, FAIL 0, ADVISORY 1, an ADVISORY line names the probe"
else fail "2-subject" "rc=$RC fail=$(num "$WORK/a2.log" FAIL) advisory=$(num "$WORK/a2.log" ADVISORY); an advisory row must not make the walk unclean"; fi

RC="$(_run "$WORK/a2" "$WORK/a3.log" "$BLK")"
if [ "$RC" -eq 1 ] && [ "$(num "$WORK/a3.log" FAIL)" = "1" ] && [ "$(num "$WORK/a3.log" ADVISORY)" != "1" ]; then
    pass "(3) the same probe with its row set to blocking is a FAIL and the walk exits 1"
else fail "3-blocking" "rc=$RC fail=$(num "$WORK/a3.log" FAIL); flipping the row to blocking must restore the red"; fi

RC="$(_run "$WORK/a2" "$WORK/a4.log" "$WORK/does-not-exist.tsv")"
if [ "$RC" -eq 1 ] && [ "$(num "$WORK/a4.log" FAIL)" = "1" ]; then pass "(4) a missing scope file fails closed: blocking, FAIL, rc 1"
else fail "4-closed" "rc=$RC; an unreadable scope file must never read as advisory"; fi

_suite "$WORK/a5" "aa_hard:hard_fail" "zz_score:advisory_red"
RC="$(_run "$WORK/a5" "$WORK/a5.log" "$ADV")"
if [ "$RC" -eq 1 ] && [ "$(num "$WORK/a5.log" FAIL)" = "1" ] && [ "$(num "$WORK/a5.log" ADVISORY)" = "1" ]; then
    pass "(5) an advisory beside a real FAIL: FAIL 1, ADVISORY 1, rc 1 (the advisory cannot mask it)"
else fail "5-mask" "rc=$RC fail=$(num "$WORK/a5.log" FAIL) advisory=$(num "$WORK/a5.log" ADVISORY)"; fi

QA="$REPO_ROOT/scripts/post_walk_qa.sh"
if [ -r "$QA" ] && awk '/^FAILED:/{f=1;next} f&&/^  [A-Za-z0-9._-]+$/{print $1} f&&!/^  [A-Za-z0-9._-]+$/{exit}' "$WORK/a5.log" | grep -q '^aa_hard$'; then
    pass "(6) the FAILED block still lists aa_hard as a bare name for post_walk_qa's parser"
else fail "6-parser" "the FAILED section no longer parses to a bare probe name"; fi

[ "$FAILED" -eq 0 ] && echo "ALL ARMS PASSED" || echo "AT LEAST ONE ARM FAILED"
exit "$FAILED"
