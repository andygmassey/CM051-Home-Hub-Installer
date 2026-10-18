#!/usr/bin/env bash
# A CANNOT-RUN IS NOT A PASS, AND THE EXIT CODE MUST SAY SO.
#
# ============================================================================
# THE DEFECT
# ============================================================================
#
# scripts/box_walk_probes/run_box_walk.sh ended:
#
#     if [ "$FAIL" -gt 0 ] || [ "$BROKEN" -gt 0 ]; then
#         exit 1
#     fi
#     exit 0
#
# so a walk exited 0 whatever CANNOT was. Twenty-one probes, twenty refusing,
# one passing: exit 0. The four-number headline printed the truth and the one
# number a caller can act on threw it away. That is the structural reason a
# probe that refuses instead of failing costs nothing, and refusing is
# therefore the cheap path.
#
# LAUNCH DIRECTIVE item 3 (CLAUDE.md, Andy, 2026-09-07) had already decided the
# rule, verbatim: "Andy is asked to walk ONLY when the thin walk reports 0 FAIL
# and the only CANNOT-RUNs are TCC/GUI items. Never before." The exit code
# simply did not implement it. This test is that sentence, executable.
#
# ============================================================================
# WHAT IS ASSERTED, AND WHY EACH ARM EXISTS
# ============================================================================
#
#   1  CONTROL, AND IT IS THE ONE THAT KEEPS THE REST HONEST. A fixture suite
#      where everything passes still exits 0. Without it, "the runner exits
#      non-zero" is satisfied by a runner that is simply broken, and every
#      other arm below would pass on a dead harness.
#   2  THE SUBJECT. 0 FAIL, 0 BROKEN, one CANNOT-RUN from a probe nobody
#      declared: exit 3, and the probe NAMED in the output. This is the exact
#      input that exited 0 before the fix.
#   3  A DECLARED console-only probe (surface tcc) still exits 0, so the change
#      is not "always fail".
#   4  The same for surface gui, because the directive names two surfaces and a
#      register that only honours one of them is half a register.
#   5  A TYPO IS NOT AN EXEMPTION. A row naming the probe with any other
#      surface leaves it non-exempt. The register's value is that someone had
#      to write a legible reason; a misspelling that silently exempted would
#      restore the defect through the fix.
#   6  AN ABSENT REGISTER IS NOT A BLANKET EXEMPTION. Delete the file and the
#      same CANNOT-RUN is still coverage lost. Absent and empty must not
#      differ, and both must fail closed.
#   7  A REAL FAILURE STILL OUTRANKS COVERAGE. A FAIL beside an EXEMPT
#      CANNOT-RUN exits 1, not 3: the new branch must not be able to mask a
#      measured defect as a coverage complaint.
#   8  MUTATION CONTROL. The fix is reverted in a copy of the runner and arm 2
#      is re-run: it must then exit 0. An assertion that has never been shown
#      to fail has been run, not tested.
#   9  THE SHIPPED REGISTER IS READABLE AND HONEST: every data row names a
#      probe file that exists and a surface that is exactly tcc or gui. Its
#      row count is PRINTED, because today it is zero and an assertion over
#      zero rows proves nothing unless the denominator is on screen.
#  10  REGRESSION GUARD, the same one the sibling test carries. The new block
#      is printed into output that post_walk_qa.sh parses with an awk that
#      accepts only bare probe names and EXITS at the first line that is not
#      one. So the REAL parser is run over the REAL runner output and must
#      still recover every name. A fix that truncated walks/<version>.tsv to
#      one row would be a worse defect than the one being fixed.
#
# Exit codes: 0 every arm passed, 1 an arm failed, 2 CANNOT-RUN (a file this
# test needs is absent, so nothing was measured).
#
# /bin/bash ON PURPOSE throughout. The cut host walks under macOS system bash
# 3.2; a developer box usually has Homebrew bash 5 first on PATH, and bash 5
# accepts 3.2-invalid syntax. Testing through PATH would green-light a runner
# that dies on the box.
# ============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$REPO_ROOT/scripts/box_walk_probes/run_box_walk.sh"
LIB="$REPO_ROOT/scripts/box_walk_probes/lib"
REGISTER="$REPO_ROOT/scripts/box_walk_probes/console_only_probes.tsv"
PROBES_DIR="$REPO_ROOT/scripts/box_walk_probes/probes"
QA="$REPO_ROOT/scripts/post_walk_qa.sh"

EX_COVERAGE_LOST=3

FAILED=0
fail() { echo "FAIL [$1]: $2" >&2; FAILED=1; }
pass() { echo "PASS: $1"; }

for f in "$RUNNER" "$LIB/probe.sh" "$REGISTER" "$QA"; do
    [ -e "$f" ] || { echo "CANNOT-RUN: $f not found. Nothing was checked, which is not a pass." >&2; exit 2; }
done
[ -d "$PROBES_DIR" ] || { echo "CANNOT-RUN: $PROBES_DIR not found. Nothing was checked." >&2; exit 2; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------------------
# A hermetic suite: the real runner, the real lib, fixture probes. Each call
# builds the suite from scratch so no arm can inherit another's register.
# ---------------------------------------------------------------------------
_probe_file() { # $1 = dir, $2 = name, $3 = pass|cannot|fail
    local dir="$1" name="$2" kind="$3"
    local body
    case "$kind" in
        pass)   body='probe_pass "fixture measured fine"' ;;
        cannot) body='probe_cannot_run "the fixture prerequisite is absent; NOTHING was measured"' ;;
        fail)   body='probe_fail "the fixture found a defect"' ;;
    esac
    cat > "${dir}/probes/${name}.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
. "\$(dirname "\${BASH_SOURCE[0]}")/../lib/probe.sh"
PROBE_NAME="${name}"
PROBE_QUESTION="a fixture probe for the exit-code contract"
run_probe() {
    probe_examined 1 "fixture thing"
    ${body}
}
self_test() {
    probe_examined 1 "fixture thing"
    probe_fail "negative control"
}
probe_main "\$@"
EOF
    chmod +x "${dir}/probes/${name}.sh"
}

# $1 = suite dir, then pairs of name:kind. Register rows come from $REG_ROWS
# (a tab-separated multi-line string) unless REG_ABSENT=1.
_build_suite() {
    local dir="$1"; shift
    rm -rf "$dir"; mkdir -p "$dir/probes" "$dir/lib"
    cp "$RUNNER" "$dir/run_box_walk.sh"
    cp "$LIB"/*.sh "$dir/lib/"
    local spec
    for spec in "$@"; do _probe_file "$dir" "${spec%%:*}" "${spec##*:}"; done
    if [ "${REG_ABSENT:-0}" -ne 1 ]; then
        {
            printf '# fixture register, same shape as the shipped one\n'
            [ -n "${REG_ROWS:-}" ] && printf '%s\n' "$REG_ROWS"
        } > "$dir/console_only_probes.tsv"
    fi
}

_run_suite() { # $1 = suite dir, $2 = log path; echoes the exit code
    local rc=0
    ( cd "$1" && /bin/bash ./run_box_walk.sh ) > "$2" 2>&1 || rc=$?
    echo "$rc"
}

TAB="$(printf '\t')"

# ---- 1. CONTROL: an all-passing suite exits 0 -----------------------------
REG_ROWS="" REG_ABSENT=0 _build_suite "$WORK/a1" "aaa_ok:pass" "bbb_ok:pass"
RC="$(_run_suite "$WORK/a1" "$WORK/a1.log")"
N_PASS="$(awk '$1=="PASS" && NF==2 && $2 ~ /^[0-9]+$/ {print $2; exit}' "$WORK/a1.log")"
N_CANNOT="$(awk '$1=="CANNOT-RUN" && NF==2 && $2 ~ /^[0-9]+$/ {print $2; exit}' "$WORK/a1.log")"
if [ "${N_PASS:-x}" = "2" ] && [ "${N_CANNOT:-x}" = "0" ] && [ "$RC" -eq 0 ]; then
    pass "(1) control: a suite where everything ran and passed exits 0 (pass=2 cannot_run=0). A green is reachable, so the arms below are not measuring a dead harness."
else
    fail "1-control" "expected pass=2 cannot_run=0 rc=0, got pass=${N_PASS:-none} cannot_run=${N_CANNOT:-none} rc=${RC}. NOTHING BELOW IS TRUSTWORTHY."
    sed 's/^/    /' "$WORK/a1.log" >&2
    exit 1
fi

# ---- 2. SUBJECT: an undeclared CANNOT-RUN is not a pass -------------------
REG_ROWS="" REG_ABSENT=0 _build_suite "$WORK/a2" "aaa_ok:pass" "zzz_shrugs:cannot"
RC2="$(_run_suite "$WORK/a2" "$WORK/a2.log")"
N2_FAIL="$(awk '$1=="FAIL" && NF==2 && $2 ~ /^[0-9]+$/ {print $2; exit}' "$WORK/a2.log")"
N2_CANNOT="$(awk '$1=="CANNOT-RUN" && NF==2 && $2 ~ /^[0-9]+$/ {print $2; exit}' "$WORK/a2.log")"
if [ "${N2_FAIL:-x}" != "0" ] || [ "${N2_CANNOT:-x}" != "1" ]; then
    fail "2-shape" "the subject suite did not produce fail=0 cannot_run=1 (got fail=${N2_FAIL:-none} cannot_run=${N2_CANNOT:-none}); arm 2 is measuring the wrong input."
elif [ "$RC2" -eq "$EX_COVERAGE_LOST" ]; then
    pass "(2) 0 FAIL, 0 BROKEN and one UNDECLARED CANNOT-RUN exits ${EX_COVERAGE_LOST}, not 0. This exact input exited 0 before the fix."
else
    fail "2-subject" "expected rc=${EX_COVERAGE_LOST} for fail=0 cannot_run=1 undeclared, got rc=${RC2}. A walk that could not measure is reporting success."
fi
# and it must NAME the probe, not merely refuse
if [ "$(/usr/bin/grep -c 'zzz_shrugs' "$WORK/a2.log")" -gt 0 ] \
   && [ "$(/usr/bin/grep -c 'COVERAGE LOST' "$WORK/a2.log")" -gt 0 ]; then
    pass "(2b) the unmeasured probe is named on the console under COVERAGE LOST"
else
    fail "2b-unnamed" "the refusal does not name zzz_shrugs under a COVERAGE LOST heading, so an operator is told a walk is not clean and not which instrument shrugged."
fi

# ---- 3 and 4. a DECLARED console-only probe still exits 0 -----------------
for surface in tcc gui; do
    REG_ROWS="zzz_shrugs${TAB}${surface}${TAB}fixture: needs a human at the machine" \
        REG_ABSENT=0 _build_suite "$WORK/a3_${surface}" "aaa_ok:pass" "zzz_shrugs:cannot"
    RC3="$(_run_suite "$WORK/a3_${surface}" "$WORK/a3_${surface}.log")"
    if [ "$RC3" -eq 0 ]; then
        pass "(3/${surface}) a CANNOT-RUN from a probe DECLARED console-only (surface ${surface}) still exits 0, so the fix is not 'always fail'"
    else
        fail "3-${surface}" "a declared ${surface} probe's CANNOT-RUN exited ${RC3}; the directive's own exemption does not work, so the only way to a clean walk would be to have no console-only probes at all."
    fi
done

# ---- 5. a typo in the surface column is not an exemption ------------------
REG_ROWS="zzz_shrugs${TAB}console${TAB}fixture: surface is not tcc or gui" \
    REG_ABSENT=0 _build_suite "$WORK/a5" "aaa_ok:pass" "zzz_shrugs:cannot"
RC5="$(_run_suite "$WORK/a5" "$WORK/a5.log")"
if [ "$RC5" -eq "$EX_COVERAGE_LOST" ]; then
    pass "(5) a row whose surface is neither tcc nor gui leaves the probe NON-exempt (rc=${RC5})"
else
    fail "5-typo" "a surface of 'console' was honoured as an exemption (rc=${RC5}). A misspelling would then be a silent blanket pass, which is the defect this fix exists to remove."
fi

# ---- 6. an absent register is not a blanket exemption ---------------------
REG_ROWS="" REG_ABSENT=1 _build_suite "$WORK/a6" "aaa_ok:pass" "zzz_shrugs:cannot"
[ -e "$WORK/a6/console_only_probes.tsv" ] && fail "6-setup" "the fixture register was written when this arm needs it absent"
RC6="$(_run_suite "$WORK/a6" "$WORK/a6.log")"
if [ "$RC6" -eq "$EX_COVERAGE_LOST" ]; then
    pass "(6) with NO register at all the same CANNOT-RUN is still coverage lost (rc=${RC6}). Absent is not empty and neither is an exemption."
else
    fail "6-absent" "with the register absent the walk exited ${RC6}. Deleting the list would then exempt everything, so the guard could be removed by removing its evidence."
fi

# ---- 7. a real failure still outranks coverage ----------------------------
REG_ROWS="zzz_shrugs${TAB}tcc${TAB}fixture: needs a human at the machine" \
    REG_ABSENT=0 _build_suite "$WORK/a7" "aaa_ok:pass" "mmm_breaks:fail" "zzz_shrugs:cannot"
RC7="$(_run_suite "$WORK/a7" "$WORK/a7.log")"
if [ "$RC7" -eq 1 ]; then
    pass "(7) a FAIL beside an exempt CANNOT-RUN still exits 1, so the new branch cannot downgrade a measured defect"
else
    fail "7-fail-outranks" "expected rc=1 with fail=1, got rc=${RC7}."
fi

# ---- 8. MUTATION CONTROL: revert the fix, arm 2 must go green -------------
# The mutant is the shipped behaviour of 2026-09-22: exit 0 whenever FAIL and
# BROKEN are 0. If arm 2's predicate cannot tell the mutant from the fix, arm 2
# proves nothing about either.
REG_ROWS="" REG_ABSENT=0 _build_suite "$WORK/a8" "aaa_ok:pass" "zzz_shrugs:cannot"
MUT="$WORK/a8/run_box_walk.sh"
/usr/bin/sed -i '' 's/^if \[ "\$NOT_EXEMPT" -gt 0 \]; then$/if [ "$NOT_EXEMPT" -gt 99999 ]; then/' "$MUT"
MUT_APPLIED="$(/usr/bin/grep -c 'NOT_EXEMPT" -gt 99999' "$MUT")"
if [ "$MUT_APPLIED" -ne 1 ]; then
    fail "8-not-applied" "the mutation did not apply (${MUT_APPLIED} sites). A mutant that did not apply looks exactly like one that was not caught, so arm 8 measured nothing."
else
    RC8="$(_run_suite "$WORK/a8" "$WORK/a8.log")"
    if [ "$RC8" -eq 0 ]; then
        pass "(8) mutation control: with the coverage branch disabled the SAME input exits 0, so arm 2 discriminates and has been seen to fail"
    else
        fail "8-mutant-survived" "the mutant still exited ${RC8}; arm 2's predicate is not what is producing its verdict."
    fi
fi

# ---- 9. the SHIPPED register is readable and honest -----------------------
ROWS="$(awk -F'\t' 'substr($0,1,1) != "#" && NF > 0 && $0 !~ /^[[:space:]]*$/ {print}' "$REGISTER" | wc -l | tr -d ' ')"
echo "note: the shipped register declares ${ROWS} console-only probe(s) out of $(ls "$PROBES_DIR"/*.sh | wc -l | tr -d ' ') probes"
BAD=0
while IFS="$TAB" read -r p s _w; do
    [ -n "${p:-}" ] || continue
    case "$s" in tcc|gui) ;; *) echo "  bad surface '${s:-}' for '${p}'" >&2; BAD=1 ;; esac
    [ -f "${PROBES_DIR}/${p}.sh" ] || { echo "  no such probe: ${p}" >&2; BAD=1; }
done < <(awk -F'\t' 'substr($0,1,1) != "#" && NF > 0 && $0 !~ /^[[:space:]]*$/ {print}' "$REGISTER")
if [ "$BAD" -eq 0 ]; then
    pass "(9) every one of the ${ROWS} declared row(s) names a probe that exists and a surface that is exactly tcc or gui"
else
    fail "9-register" "the shipped register carries a row naming a probe that does not exist or a surface that is not tcc/gui. Such a row is silently non-exempt, so its author believes they wrote an exemption and did not."
fi

# ---- 10. REGRESSION GUARD: the record parser still sees every name --------
# post_walk_qa.sh's section_names() grabs bare probe names under a header and
# EXITS at the first line that is not one. The new block is printed after those
# sections; if it ever moved above one, walks/<version>.tsv would silently lose
# rows. Run the REAL parser over the REAL output of arm 2.
PARSED="$(awk -v hdr='NOT MEASURED' '
    index($0, hdr) == 1 { grab = 1; next }
    grab && $0 ~ /^[[:space:]]*$/ { exit }
    grab && $0 ~ /^  [A-Za-z0-9._-]+$/ { sub(/^  /, ""); print; next }
    grab { exit }
' "$WORK/a2.log")"
if [ "$PARSED" = "zzz_shrugs" ]; then
    pass "(10) post_walk_qa.sh's own section parser still recovers the not-measured name from the runner's output"
else
    fail "10-parser" "the record parser returned '$(printf '%s' "$PARSED" | tr '\n' ' ')' instead of 'zzz_shrugs'. The new block has broken the walk record's own parse, which loses rows silently."
fi

echo
if [ "$FAILED" -eq 0 ]; then
    echo "ALL ARMS PASSED (10 arms; 1 control, 1 mutation control)"
else
    echo "AT LEAST ONE ARM FAILED" >&2
fi
exit "$FAILED"
