#!/usr/bin/env bash
# tests/test_a_denied_read_is_not_an_absence.sh
# ============================================================================
# A READ THE PROBE WAS REFUSED MUST NEVER BE REPORTED AS A FILE THAT IS NOT
# THERE.                                                    (v1.0.46 BOM row 6)
# ============================================================================
#
# THE DEFECT, measured 2026-08-25 on the pre-fix file.
#
# The BOM row that blocked the claim:
#
#     installed_bundle_seal_intact reports all three Ostler bundles MISSING
#     from /Applications while a direct SSH read finds /Applications/Ostler.app
#     present (short=0.7.1, mtime 22 Aug 17:34). One of the two readers is
#     lying and neither may be cited until it is known which.
#
# The probe's entire reading was one operator:
#
#     if [[ ! -d "$app" ]]; then echo "  MISSING   $app"
#
# `[[ -d ]]` is false for a path that is not there AND for a path whose parent
# cannot be searched, and it prints the same word for both. So three facts that
# must be acted on differently -- present, absent, refused -- shared one
# appearance, and the verdict carried no record of what had been inspected:
# no host, no uid, no resolved path, no errno. Nothing to adjudicate with.
#
# WHAT ACTUALLY SETTLED IT was the second half of the same fault. The probe
# named no ssh, no box_run and no OSTLER_BOX_HOST, so it read the OPERATOR's
# /Applications while every sibling probe read the box. Watched, pre-fix:
#
#     OSTLER_BOX_HOST=operator@definitely-not-a-real-box.invalid \
#         bash probes/installed_bundle_seal_intact.sh
#     -> MISSING x3, rc=2
#
# A full verdict about a host whose name does not resolve.
#
# ---------------------------------------------------------------------------
# WHAT THIS TEST PINS
# ---------------------------------------------------------------------------
#
# It drives the REAL reader -- scripts/box_walk_probes/lib/bundle_inspect.py,
# the same file the probe ships to the box -- over a fixture holding one of
# each outcome, and requires three distinguishable answers. Then it MUTATES
# that reader so a refused read is classified as absence, and requires the
# probe's own negative control to notice. A control that cannot be made to fail
# has not proved anything, and every gate that burned a tag in this repo was
# one of those.
#
# EXIT CODES   0 all controls pass   1 a control failed   2 CANNOT-RUN
# ============================================================================

set -uo pipefail

REPO_ROOT="${1:-}"
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

SUITE="${REPO_ROOT}/scripts/box_walk_probes"
READER="${SUITE}/lib/bundle_inspect.py"
PROBE="${SUITE}/probes/installed_bundle_seal_intact.sh"

PASS=0
FAIL=0
cannot_run() { echo "CANNOT-RUN: $*" >&2; exit 2; }
pass()    { printf '  [pass] %s\n' "$1"; PASS=$((PASS + 1)); }
failure() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v python3 >/dev/null 2>&1 || cannot_run "no python3; the reader could not be driven at all"
[[ -f "$READER" ]] || cannot_run "the reader is not at $READER, so nothing was tested"
[[ -f "$PROBE"  ]] || cannot_run "the probe is not at $PROBE, so nothing was tested"

echo "test_a_denied_read_is_not_an_absence.sh"
echo

WORK="$(mktemp -d "${TMPDIR:-/tmp}/deniedread.XXXXXX")" \
    || cannot_run "could not create a working directory"
# chmod back before rm, or the cleanup silently leaves the fixture behind.
cleanup() { chmod 700 "${WORK}/fix/blocked" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

FIX="${WORK}/fix"
mkdir -p "${FIX}/Present.app/Contents" "${FIX}/blocked/Blocked.app"
cat > "${FIX}/Present.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>CFBundleShortVersionString</key><string>0.0.0-fixture</string>
</dict></plist>
PLIST
chmod 000 "${FIX}/blocked"

# uid 0 walks through a 000 directory whatever its mode says, so the arm that
# matters cannot be built as root. That is CANNOT-RUN. Reporting the other two
# arms as a pass would be exactly the "we did not measure this, call it green"
# move the whole suite exists to refuse.
if [[ "$(id -u)" == "0" ]]; then
    cannot_run "running as uid 0: a 000 directory does not deny root, so the refused-read arm cannot be constructed and the central assertion of this test cannot be made."
fi

# Independent confirmation that the fixture really does deny this process --
# the FIXTURE is what the test rests on, and a fixture that quietly grants
# access would make every assertion below vacuous.
if ls "${FIX}/blocked" >/dev/null 2>&1; then
    cannot_run "the 000 fixture directory is still listable by this process, so the refused-read case was never constructed."
fi

state_of() {  # state_of <report> <requested-path>
    printf '%s\n' "$1" | grep -F "requested=$2	" | head -1 \
        | tr '\t' '\n' | sed -n 's/^state=//p' | head -1
}
value_of() {  # value_of <report> <requested-path> <key>
    printf '%s\n' "$1" | grep -F "requested=$2	" | head -1 \
        | tr '\t' '\n' | sed -n "s/^$3=//p" | head -1
}

# ---------------------------------------------------------------------------
# (0) THE SHIPPING INVARIANT. The probe wraps this source in single quotes to
#     hand it to the remote shell. One apostrophe anywhere and the command the
#     box receives does not parse -- a reader that produces no reading, which
#     is the family of defect being fixed. Assert the property, not a comment
#     asking for it.
# ---------------------------------------------------------------------------
if grep -q "'" "$READER"; then
    failure "(0) the reader contains a single-quote character; the command the probe ships to the box would not parse"
else
    pass "(0) the reader carries no single quote, so it survives being shipped to the box"
fi

# ---------------------------------------------------------------------------
# (1) POSITIVE CONTROL FIRST. Without it, a reader that answered CANNOT-LOOK
#     to everything would satisfy every assertion below and look correct.
# ---------------------------------------------------------------------------
REPORT="$(python3 "$READER" \
    "${FIX}/Present.app" "${FIX}/Absent.app" "${FIX}/blocked/Blocked.app" 2>&1)" || {
    failure "(1) the reader exited non-zero; output: $(printf '%s' "$REPORT" | tr '\n' ' ' | cut -c1-300)"
    REPORT=""
}

S_PRESENT="$(state_of "$REPORT" "${FIX}/Present.app")"
S_ABSENT="$(state_of "$REPORT" "${FIX}/Absent.app")"
S_BLIND="$(state_of "$REPORT" "${FIX}/blocked/Blocked.app")"

if [[ "$S_PRESENT" == "PRESENT" ]]; then
    pass "(1) POSITIVE CONTROL: a bundle that is really there reads as PRESENT (short=$(value_of "$REPORT" "${FIX}/Present.app" short))"
else
    failure "(1) POSITIVE CONTROL FAILED: a bundle that is really there read as '${S_PRESENT:-<no record>}'. This reader cannot see, so nothing below means anything."
fi

# ---------------------------------------------------------------------------
# (2) THREE OUTCOMES, THREE APPEARANCES. Asserted as a set size, because the
#     property is that no two collapse onto each other.
# ---------------------------------------------------------------------------
DISTINCT="$(printf '%s\n%s\n%s\n' "$S_PRESENT" "$S_ABSENT" "$S_BLIND" | sort -u | grep -c .)"
if [[ "${DISTINCT:-0}" -eq 3 ]]; then
    pass "(2) present / absent / refused are three distinct verdicts (${S_PRESENT} / ${S_ABSENT} / ${S_BLIND})"
else
    failure "(2) VERDICTS COLLAPSED: present=${S_PRESENT:-<none>} absent=${S_ABSENT:-<none>} refused=${S_BLIND:-<none>} -> only ${DISTINCT} distinct value(s)"
fi

# ---------------------------------------------------------------------------
# (3) THE ASSERTION THIS FILE IS NAMED FOR.
# ---------------------------------------------------------------------------
if [[ "$S_BLIND" == "ABSENT" ]]; then
    failure "(3) A REFUSED READ WAS REPORTED AS AN ABSENCE. ${FIX}/blocked/Blocked.app sits behind a 000 directory and the reader called it missing. This is v1.0.46 BOM row 6, live again."
elif [[ "$S_BLIND" == "CANNOT-LOOK" ]]; then
    pass "(3) a refused read reports CANNOT-LOOK, not absence"
else
    failure "(3) a refused read produced '${S_BLIND:-<no record>}', which is neither CANNOT-LOOK nor a recognised verdict"
fi

BLIND_ERRNO="$(value_of "$REPORT" "${FIX}/blocked/Blocked.app" errno)"
if [[ "$BLIND_ERRNO" == "EACCES" || "$BLIND_ERRNO" == "EPERM" ]]; then
    pass "(3b) the refusal carries the raw errno (${BLIND_ERRNO}), not a collapsed boolean"
else
    failure "(3b) the refusal reported errno='${BLIND_ERRNO:-<none>}'; without the errno an operator cannot tell a denial from a bug"
fi

# ---------------------------------------------------------------------------
# (4) AN ABSENCE MUST CARRY ITS DENOMINATOR. "stat failed" is not proof that a
#     thing is not there; enumerating the directory it would be in is.
# ---------------------------------------------------------------------------
LISTED="$(value_of "$REPORT" "${FIX}/Absent.app" listed)"
ENTRIES="$(value_of "$REPORT" "${FIX}/Absent.app" entries)"
if [[ -n "$LISTED" && -n "$ENTRIES" && "$ENTRIES" != "-" ]]; then
    pass "(4) the ABSENT verdict names the directory it enumerated (${LISTED}, ${ENTRIES} entries)"
else
    failure "(4) the ABSENT verdict carries no listed=/entries= denominator, so absence was asserted rather than proved"
fi

# ---------------------------------------------------------------------------
# (5) THE RESOLVED PATH AND THE READING CONTEXT. A verdict about a path that
#     is never printed cannot be checked against the machine it came from.
# ---------------------------------------------------------------------------
for key in resolved expanded; do
    if [[ -n "$(value_of "$REPORT" "${FIX}/Absent.app" "$key")" ]]; then
        pass "(5) the record prints the ${key} path it actually stat'd"
    else
        failure "(5) the record has no ${key}= field; the path inspected is unknown"
    fi
done

HOSTREC="$(printf '%s\n' "$REPORT" | grep '^HOST' | head -1)"
MISSING_FIELDS=""
for key in hostname uid euid transport; do
    grep -q "	${key}=" <<< "$HOSTREC" || MISSING_FIELDS="${MISSING_FIELDS} ${key}"
done
if [[ -z "$MISSING_FIELDS" ]]; then
    pass "(5b) the reader states which machine and which uid produced the verdict"
else
    failure "(5b) the HOST record omits:${MISSING_FIELDS}"
fi

if grep -q '^CONTEXT.*tcc=' <<< "$REPORT"; then
    pass "(5c) the reader states the TCC/sandbox regime it read under"
else
    failure "(5c) no CONTEXT record with a tcc= field; a TCC denial would be unattributable"
fi

# ---------------------------------------------------------------------------
# (6) MUTATION. Everything above passes for a reader that is right today. It
#     would ALSO pass for one that had merely stopped being able to go wrong.
#     So the defect is rebuilt inside a copy of the real reader, twice, and the
#     two mutations answer different questions.
#
#     A control that cannot be made to fire is not a control.
# ---------------------------------------------------------------------------
MUT="${WORK}/mutant"
mkdir -p "${MUT}/lib" "${MUT}/probes"
cp "${SUITE}/lib/probe.sh" "${MUT}/lib/probe.sh"
cp "$PROBE" "${MUT}/probes/installed_bundle_seal_intact.sh"

# (6a) MUTATION ONE -- fold EACCES/EPERM into the errnos that mean "not there",
#      which is the naive fix someone will eventually make. MEASURED 2026-08-25:
#      this one does NOT kill the reader, and that is the finding, not a
#      disappointment. The verdict survives because absence is never taken from
#      a failed stat alone -- it must be corroborated by enumerating an
#      ancestor, and the 000 directory cannot be enumerated either. Two
#      independent defences, and this control pins the second one so a later
#      simplification that deletes highest_listable_ancestor() goes red here.
MUT_A="${WORK}/mutant_a.py"
sed 's/^ABSENCE_ERRNOS = (errno_mod.ENOENT, errno_mod.ENOTDIR)$/ABSENCE_ERRNOS = (errno_mod.ENOENT, errno_mod.ENOTDIR, errno_mod.EACCES, errno_mod.EPERM)/' \
    "$READER" > "$MUT_A"
if diff -q "$READER" "$MUT_A" >/dev/null 2>&1; then
    failure "(6a) MUTATION DID NOT APPLY: the ABSENCE_ERRNOS line was not found, so this control tests nothing"
else
    MUT_A_STATE="$(state_of "$(python3 "$MUT_A" "${FIX}/blocked/Blocked.app" 2>&1)" "${FIX}/blocked/Blocked.app")"
    if [[ "$MUT_A_STATE" == "CANNOT-LOOK" ]]; then
        pass "(6a) DEFENCE IN DEPTH: even with EACCES declared an absence errno, the refused read still reads CANNOT-LOOK, because absence also requires enumerating an ancestor and the 000 directory cannot be enumerated"
    else
        failure "(6a) the second defence is gone: with EACCES in the absence errnos the reader answered '${MUT_A_STATE:-<none>}'. Only one thing now stands between a denial and a false absence."
    fi
fi

# (6b) MUTATION TWO -- THE KILLING ONE. Collapse the refused-read verdict onto
#      the absence verdict, which is literally what `[[ ! -d "$app" ]] && echo
#      MISSING` did: two facts, one word. Nothing downstream can recover the
#      distinction once the strings are equal, so this must be caught.
sed 's/^CANNOT_LOOK = "CANNOT-LOOK"$/CANNOT_LOOK = "ABSENT"/' \
    "$READER" > "${MUT}/lib/bundle_inspect.py"

if diff -q "$READER" "${MUT}/lib/bundle_inspect.py" >/dev/null 2>&1; then
    failure "(6b) MUTATION DID NOT APPLY: the CANNOT_LOOK constant was not found, so this control tests nothing. Fix the mutation before trusting (3)."
else
    MUT_REPORT="$(python3 "${MUT}/lib/bundle_inspect.py" "${FIX}/blocked/Blocked.app" 2>&1)"
    MUT_STATE="$(state_of "$MUT_REPORT" "${FIX}/blocked/Blocked.app")"
    if [[ "$MUT_STATE" == "ABSENT" ]]; then
        pass "(6b) MUTATION LIVE: with the two verdicts collapsed the mutant reader does call a refused read missing -- so the fixture genuinely exercises the defect"
    else
        failure "(6b) MUTATION INERT: the mutant answered '${MUT_STATE:-<none>}'. The fixture does not exercise the defect, so (3) is passing for some other reason."
    fi

    # ...and the probe's negative control must NOTICE. Run the real probe from
    # the mutated tree. Per this suite's inversion a self-test that behaves
    # exits 1; one that reports NEGATIVE CONTROL DID NOT FIRE exits 0, which
    # run_box_walk.sh reads as BROKEN and whose result it discards.
    #
    # No `set +e` guard here, deliberately: this file runs under `set -uo
    # pipefail` and errexit is never on. Toggling it around a block that is
    # EXPECTED to exit non-zero would leave errexit ENABLED for everything
    # after it, which is a different script from the one that was tested.
    MUT_OUT="$(bash "${MUT}/probes/installed_bundle_seal_intact.sh" --self-test 2>&1)"
    MUT_RC=$?
    if grep -q 'NEGATIVE CONTROL DID NOT FIRE' <<< "$MUT_OUT" && [[ "$MUT_RC" -eq 0 ]]; then
        pass "(6c) the probe's own negative control CATCHES the killing mutant (rc=${MUT_RC}, reported NEGATIVE CONTROL DID NOT FIRE, which run_box_walk marks BROKEN)"
    else
        failure "(6c) the probe's negative control did NOT catch a reader that calls a refused read missing (rc=${MUT_RC}): $(printf '%s' "$MUT_OUT" | tr '\n' ' ' | cut -c1-300)"
    fi
fi

# ---------------------------------------------------------------------------
# (7) THE OTHER HALF OF ROW 6: THE COMPARTMENT. A probe told to measure a box
#     must not answer about the machine it is running on. Driven behaviourally
#     against a host whose name cannot resolve (RFC 2606 reserves .invalid),
#     because the pre-fix file produced a confident three-line verdict here.
# ---------------------------------------------------------------------------
COMP_OUT="$(OSTLER_BOX_HOST=nobody@definitely-not-a-real-box.invalid \
            OSTLER_SSH_TIMEOUT=5 bash "$PROBE" 2>&1)"
COMP_RC=$?

if [[ "$COMP_RC" -eq 78 ]]; then
    pass "(7) an unreachable box gives CANNOT-RUN (78), not a verdict"
else
    failure "(7) with an unresolvable box host the probe exited ${COMP_RC}, not 78 CANNOT-RUN"
fi

if grep -qE '(ABSENT|MISSING|VERDICT: (PASS|FAIL))' <<< "$COMP_OUT"; then
    failure "(7b) THE PROBE ANSWERED ABOUT THE WRONG COMPUTER: asked about an unreachable box it still reported on local paths: $(printf '%s' "$COMP_OUT" | tr '\n' ' ' | cut -c1-300)"
else
    pass "(7b) the probe reports nothing about local /Applications when the box it was pointed at is unreachable"
fi

if grep -qi 'ssh\|resolve\|transport said' <<< "$COMP_OUT"; then
    pass "(7c) the CANNOT-RUN names the transport failure instead of swallowing stderr"
else
    failure "(7c) the CANNOT-RUN does not say why the box could not be reached: $(printf '%s' "$COMP_OUT" | tr '\n' ' ' | cut -c1-200)"
fi

echo
echo "=== ${PASS} passed / ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
