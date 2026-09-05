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

SHA=0000000000000000000000000000000000000000000000000000000000000000

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

# A verdict with no named subject.
D="${WORK}/e"; _rec "$D" FAILED
R="$(_run "$D")"
case "$R" in
    2\|*) ok "a FAILED verdict naming no probe refuses -- a verdict with no subject cannot be scoped" ;;
    0\|*) bad "a FAILED record naming nothing PASSED" ;;
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
