#!/usr/bin/env bash
# THE SCOPED PROMOTE MUST REFUSE ON THE ARTEFACT AND FAIL CLOSED ON EVERYTHING ELSE.
#
# WHY THIS EXISTS. Andy's decision 2026-09-05: the promote binds on the probes that
# describe the DMG, not on the whole 24-probe scoreboard. The scoreboard measures
# four different things -- this artefact, the customer's DATA, the ARCHITECTURE, and
# the OPERATOR'S BOX -- and only the first is a property of what is being promoted.
#
# ⚠️ THIS TEST EXISTS BECAUSE THE CHANGE IS A LOOSENING, AND A LOOSENING IS WHERE A
# GATE QUIETLY STOPS FIRING. Every arm below is about the gate REFUSING. The one arm
# that expects exit 0 is pinned to a record whose only non-passes are declared
# advisory, and it is followed by an arm proving that same record refuses the moment
# one probe is moved back to blocking.
#
# THREE STATES. 0 pass, 1 fail, 2 cannot-run.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
GATE="${REPO}/scripts/verify_walk_record.sh"
SCOPE="${REPO}/scripts/walk_promote_scope.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }

[ -f "$GATE" ]  || { echo "CANNOT-RUN: no gate at ${GATE}" >&2; exit 2; }
[ -f "$SCOPE" ] || { echo "CANNOT-RUN: no scope file at ${SCOPE}" >&2; exit 2; }
WORK="$(mktemp -d)" || { echo "CANNOT-RUN: no working directory" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

# A synthetic sha256: 64 hex chars, built so no run of 15+ DIGITS appears.
# 64 zeros trips ci-pii-shape-scan's \b[0-9]{15,}\b pattern, which matches on
# SHAPE rather than on known values -- a long digit run could be a phone number
# or an account id, and the guard cannot tell. Interleaving hex letters is also
# more faithful to what a real sha256 looks like. The pre-commit hook
# (operator-pii-scan) reported CLEAN on this file: it and ci-pii-shape-scan are
# different gates with different subjects, and passing one says nothing about
# the other.
SHA="$(printf '0123456789abcdef%.0s' 1 2 3 4)"

# Build a record. $1 dir, $2 verdict, then failed/not-measured probe names.
_rec() {
    local d="$1" verdict="$2"; shift 2
    mkdir -p "${d}/walks"
    local n=$#
    {
        printf 'version\tv9.9.9\n'
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'artefact_sha256\t%s\n' "$SHA"
        printf 'artefact_sha256_source\tmeasured(shasum -a 256 on the walked box)\n'
        printf 'walked_at\t2026-09-05T00:00:00Z\n'
        printf 'pass\t%d\n' $((24-n))
        printf 'fail\t%d\n' "$n"
        printf 'cannot_run\t0\n'
        printf 'broken\t0\n'
        printf 'verdict\t%s\n' "$verdict"
        printf 'qa_exit\t1\n'
        printf 'failed_probe_names_recorded\t%d of %d\n' "$n" "$n"
        local p; for p in "$@"; do printf 'failed_probe\t%s\n' "$p"; done
    } > "${d}/walks/v9.9.9.tsv"
}

# Build a record carrying BOTH kinds of non-pass. $1 dir, $2 failed csv (may be
# empty), $3 not-measured csv (may be empty).
#
# A PARTIAL record is the shape a fresh install produces: the three store-reading
# probes return CANNOT-RUN on a box whose stores are still empty, by design, so
# they land as not_measured_probe rather than failed_probe. The gate must refuse
# either way and must NOT tell the operator that a probe which could not run
# "describes the DMG".
_rec2() {
    local d="$1" failed="$2" notmeas="$3"
    mkdir -p "${d}/walks"
    local nf=0 nm=0 p
    for p in ${failed//,/ };  do nf=$((nf+1)); done
    for p in ${notmeas//,/ }; do nm=$((nm+1)); done
    {
        printf 'version\tv9.9.9\n'
        printf 'version_source\tmeasured(CFBundleShortVersionString, matches argument)\n'
        printf 'artefact_sha256\t%s\n' "$SHA"
        printf 'artefact_sha256_source\tmeasured(shasum -a 256 on the walked box)\n'
        printf 'walked_at\t2026-09-05T00:00:00Z\n'
        printf 'pass\t%d\n' $((24-nf-nm))
        printf 'fail\t%d\n' "$nf"
        printf 'cannot_run\t%d\n' "$nm"
        printf 'broken\t0\n'
        printf 'verdict\t%s\n' "$([ "$nf" -gt 0 ] && echo FAILED || echo PARTIAL)"
        printf 'qa_exit\t%s\n' "$([ "$nf" -gt 0 ] && echo 1 || echo 2)"
        printf 'failed_probe_names_recorded\t%d of %d\n' "$nf" "$nf"
        for p in ${failed//,/ };  do printf 'failed_probe\t%s\n' "$p"; done
        for p in ${notmeas//,/ }; do printf 'not_measured_probe\t%s\n' "$p"; done
    } > "${d}/walks/v9.9.9.tsv"
}

# Run the gate against a record dir. Echoes "<rc>|<output>".
_run() {
    local d="$1" scope="${2:-$SCOPE}"
    local out rc
    # OSTLER_WALK_RECORD_DIR, not cd: the gate resolves the record from its own
    # REPO_ROOT (:56), so a cd only produced "NO WALK RECORD" on every arm -- and
    # one arm PASSED on that rc=2 for entirely the wrong reason.
    out="$(OSTLER_WALK_RECORD_DIR="${d}/walks" OSTLER_PROMOTE_SCOPE="$scope" bash "$GATE" v9.9.9 "$SHA" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$out"
}

echo "── the gate must refuse on artefact-owned probes ──"

D="${WORK}/a"; _rec "$D" FAILED install_manifest_complete
R="$(_run "$D")"
case "$R" in
    1\|*ARTEFACT-OWNED*install_manifest_complete*) ok "a BLOCKING probe refuses the promote, and is NAMED" ;;
    0\|*) bad "a blocking probe PASSED the gate. The scoping is a bypass." ;;
    *)    bad "a blocking probe gave rc=${R%%|*}: $(printf '%s' "${R#*|}" | head -1)" ;;
esac

echo "── ...and must NOT refuse when every non-pass is declared advisory ──"

D="${WORK}/b"; _rec "$D" FAILED no_store_port_is_tcp_reachable usage_journal_producers
R="$(_run "$D")"
case "$R" in
    0\|*ADVISORY,\ NOT\ BLOCKING*) ok "advisory-only non-passes allow the promote AND print the advisory list" ;;
    0\|*) bad "advisory-only passed but printed no advisory list -- an unread red is the failure mode this introduces" ;;
    *)    bad "advisory-only non-passes gave rc=${R%%|*}, expected 0" ;;
esac

echo "── ...and the SAME record must refuse the moment one row moves back ──"
# This is the anti-vacuity arm: it proves the arm above passed BECAUSE of the scope
# file, not because the gate stopped looking.
MUT="${WORK}/scope_mut.tsv"
sed 's/^no_store_port_is_tcp_reachable\tadvisory/no_store_port_is_tcp_reachable\tblocking/' "$SCOPE" > "$MUT"
R="$(_run "${WORK}/b" "$MUT")"
case "$R" in
    1\|*no_store_port_is_tcp_reachable*) ok "ANTI-VACUITY: flipping one row to blocking refuses the identical record" ;;
    0\|*) bad "flipping a row to blocking changed nothing -- the gate is not reading the scope file" ;;
    *)    bad "the mutated scope gave rc=${R%%|*}" ;;
esac

echo "── fail-closed arms ──"

D="${WORK}/c"; _rec "$D" FAILED a_probe_nobody_declared
R="$(_run "$D")"
case "$R" in
    2\|*not\ declared*) ok "an UNDECLARED probe is treated as blocking, and refuses with CANNOT-RUN" ;;
    0\|*) bad "an undeclared probe PASSED. A new probe could become advisory by nobody writing its row." ;;
    *)    bad "an undeclared probe gave rc=${R%%|*}" ;;
esac

R="$(_run "${WORK}/b" "${WORK}/no_such_scope.tsv")"
case "$R" in
    2\|*unreadable*) ok "a MISSING scope file refuses: without it, which probes describe the artefact is unknown" ;;
    0\|*) bad "a missing scope file PASSED. Deleting the file would become the bypass." ;;
    *)    bad "a missing scope file gave rc=${R%%|*}" ;;
esac

# An incomplete list of failures cannot be scoped.
D="${WORK}/d"; _rec "$D" FAILED no_store_port_is_tcp_reachable
sed -i.bak 's/^failed_probe_names_recorded\t1 of 1/failed_probe_names_recorded\t1 of 3/' "${D}/walks/v9.9.9.tsv"
R="$(_run "$D")"
case "$R" in
    2\|*1\ of\ 3*) ok "an INCOMPLETE failure list refuses: an unnamed failure cannot be checked against the scope" ;;
    0\|*) bad "a record naming 1 of 3 failures PASSED. Two unnamed failures went unscoped." ;;
    *)    bad "an incomplete list gave rc=${R%%|*}" ;;
esac

echo "── a blocking probe that COULD NOT RUN describes nothing about the DMG ──"
#
# The three store-reading probes return CANNOT-RUN on an unpopulated box, so this
# is the shape a walk of a FRESH install produces before ingest has finished.
# Telling the operator those reds "describe the DMG" sends them to debug a build
# that was never measured. Both still refuse; they refuse with different codes
# and different sentences.

D="${WORK}/nm"; _rec2 "$D" "" "people_stores_reconcile"
R="$(_run "$D")"
case "$R" in
    2\|*NOT\ MEASURED*describe\ NOTHING*) ok "a blocking CANNOT-RUN refuses as rc=2 and says it measured NOTHING about the DMG" ;;
    1\|*)  bad "a blocking CANNOT-RUN returned rc=1, which says a defect was measured. Nothing was measured." ;;
    0\|*)  bad "a blocking CANNOT-RUN PASSED the gate. Coverage lost is not coverage passed." ;;
    *)     bad "a blocking CANNOT-RUN gave rc=${R%%|*}: $(printf '%s' "${R#*|}" | head -1)" ;;
esac

# THE ARM THAT KEEPS THE SPLIT HONEST. A record carrying BOTH must exit 1:
# evidence of badness outranks absence of evidence, which is the rule this file
# already states for records naming no probes at all.
D="${WORK}/both"; _rec2 "$D" "install_manifest_complete" "people_stores_reconcile"
R="$(_run "$D")"
case "$R" in
    1\|*FAILED\ --*NOT\ MEASURED*) ok "a record with BOTH kinds exits 1 and lists them SEPARATELY" ;;
    2\|*) bad "a measured defect was downgraded to rc=2 because something else could not run" ;;
    *)    bad "a record with both kinds gave rc=${R%%|*}" ;;
esac

# ...and the FAILED side must not have been relabelled. Without this, the split
# could satisfy the two arms above by calling everything NOT MEASURED.
D="${WORK}/f2"; _rec2 "$D" "install_manifest_complete" ""
R="$(_run "$D")"
case "$R" in
    1\|*FAILED\ --\ these\ MEASURED*) ok "CONTROL: a probe that genuinely FAILED is still reported as having MEASURED the DMG" ;;
    *) bad "a genuinely failed probe was not reported as measured: rc=${R%%|*}" ;;
esac

# A verdict with no named subject falls back to the OLD UNSCOPED REFUSAL (rc=1),
# NOT to CANNOT-RUN. Records predating the failed_probe format are FAILED and name
# nothing; turning them into rc=2 converts a measured failure into "nothing is
# known". I shipped exactly that regression and arm 931-9 of
# test_walk_record_gates_customer_download.sh caught it on the live v1.0.44 and
# v1.0.47 records.
#
# ⚠️ AND NOTE THE `*)` ARM. Without it this case matched neither branch when the
# expected code changed, so the check SILENTLY STOPPED COUNTING -- the suite went
# 11 arms to 10 and reported "10 pass / 0 fail". A case with no default does not
# fail, it disappears, and a shrinking denominator is the only tell.
D="${WORK}/e"; _rec "$D" FAILED
R="$(_run "$D")"
case "$R" in
    1\|*) ok "a FAILED verdict naming no probe refuses UNSCOPED (rc=1), not as CANNOT-RUN" ;;
    2\|*) bad "a nameless FAILED record returned CANNOT-RUN -- a measured failure turned into absence of evidence" ;;
    0\|*) bad "a FAILED record naming nothing PASSED" ;;
    *)    bad "a nameless FAILED record returned rc=${R%%|*}, which matches no expected arm" ;;
esac

echo "── the scope file itself ──"

_bad_rows="$(awk -F'\t' '!/^#/ && NF>0 && NF!=4' "$SCOPE" | wc -l | tr -d ' ')"
[ "$_bad_rows" -eq 0 ] && ok "every scope row has exactly 4 columns" \
                       || bad "${_bad_rows} scope row(s) do not have 4 columns"

_bad_scope="$(awk -F'\t' '!/^#/ && NF==4 && $1!="probe" && $2!="blocking" && $2!="advisory" {print $1}' "$SCOPE")"
[ -z "$_bad_scope" ] && ok "every scope value is blocking or advisory" \
                     || bad "unknown scope value on: ${_bad_scope}"

# Every probe on disk must be declared, or the fail-closed arm fires at promote time
# on a probe nobody chose -- correct, but discovered at the worst moment.
_undeclared="$(comm -23 <(ls "${REPO}/scripts/box_walk_probes/probes/" | sed 's/\.sh$//' | sort) \
                        <(awk -F'\t' '!/^#/ && NF==4 && $1!="probe"{print $1}' "$SCOPE" | sort))"
[ -z "$_undeclared" ] && ok "every probe on disk has a scope row" \
                      || bad "probe(s) on disk with no scope row: $(printf '%s' "$_undeclared" | tr '\n' ' ')"

_orphan="$(comm -13 <(ls "${REPO}/scripts/box_walk_probes/probes/" | sed 's/\.sh$//' | sort) \
                    <(awk -F'\t' '!/^#/ && NF==4 && $1!="probe"{print $1}' "$SCOPE" | sort))"
[ -z "$_orphan" ] && ok "every scope row names a probe that exists" \
                  || bad "scope row(s) naming no probe: $(printf '%s' "$_orphan" | tr '\n' ' ')"

echo
echo "== ${PASS} pass / ${FAIL} fail / $((PASS+FAIL)) total =="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
