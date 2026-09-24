#!/usr/bin/env bash
# THE CUSTOMER'S SIGN-IN MUST NOT DEPEND ON WHETHER THE WIKI HAS FINISHED
# BUILDING.
# ============================================================================
# WHAT ANDY REPORTED (HR015 #943)
#
#   "The wiki via a browser is requesting authentication details I do not have."
#   "I did NOT see the code / password for the wiki."
#
# He is right that he never saw it. IT WAS NEVER SHOWN. On origin/main the
# whole credential handover sat inside one conditional:
#
#     if [[ "$WIKI_FIRST_COMPILE_OK" == true ]]; then
#         ... address, username, password, clipboard copy ...
#     else
#         echo "  Your wiki:  not yet available (first compile failed -- see warnings above)"
#     fi
#
# When the flag was false the customer got that one line and nothing else. No
# address, no username, no password, not later, not anywhere. The wiki then
# finished compiling in the background, started serving, and the customer met a
# browser password box for a credential they had never been given.
#
# MEASURED on install.sh at origin/main: WIKI_PASSWORD is surfaced to a human
# in exactly ONE place, line 33341, and it is inside that branch. Its clipboard
# copy, line 33352, is inside the same branch. Positive control on the same
# grep: the same predicate finds the string's definition in
# install.sh.strings.en-GB.sh, so the search works and the single hit is the
# real population, not a broken pattern.
#
# TWO DEFECTS IN ONE CONDITIONAL, AND THIS GUARD COVERS BOTH
#
#   1. COUPLING. "Is the wiki serving yet" and "does the customer get their
#      sign-in" are different questions. The password is seeded hundreds of
#      steps earlier and is never rotated, so there is no state of the box in
#      which we hold it and cannot hand it over.
#
#   2. A CAUSE THAT WAS NEVER MEASURED. WIKI_FIRST_COMPILE_OK goes false for at
#      least three distinct reasons, only one of which is a failed compile:
#      `docker compose up -d wiki-site` returning non-zero, :8044 not answering
#      200 within the 60-second poll, and the baseline compile actually
#      failing. "first compile failed" was asserted on all three. Measured on
#      the v1.0.98 box: the compiler was still RUNNING an hour later and the
#      wiki then worked perfectly. Nothing had failed.
#
# HOW THIS TEST WORKS, AND WHY IT IS NOT A GREP
#
# It EXTRACTS the banner between its sentinels and EXECUTES it, once per state,
# with the strings catalogue sourced the way install.sh sources it. So it reads
# what a CUSTOMER RENDERS, not what the file contains: a message that is
# present and expands to nothing cannot pass.
#
# EXIT CODES, DELIBERATELY DISTINCT
#   0  every limb passed
#   1  at least one limb failed
#   2  CANNOT-RUN. The banner could not be extracted or executed, so NOTHING
#      was measured. That is not a pass.
# ============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${OSTLER_INSTALL_SH:-${REPO}/install.sh}"
STRINGS="${REPO}/install.sh.strings.en-GB.sh"

PASS=0; FAIL=0; CANT=0
ok()   { PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
cant() { CANT=$((CANT+1)); printf '  [CANNOT-RUN] %s\n' "$1"; }

SELF_TEST=0
[ "${1:-}" = "--self-test" ] && SELF_TEST=1

WORK="$(mktemp -d)"
cleanup() { rm -rf -- "${WORK}"; }
trap cleanup EXIT

# Synthetic throughout. Never a real credential, and deliberately shaped so it
# could not be mistaken for one if it ever appeared in a log.
SYNTH_PW='SYNTHETIC-NOT-A-REAL-CREDENTIAL-943'
# The negative control for the search predicate itself: a second synthetic that
# is never handed to the block, so a limb that greps for it must NOT find it.
SYNTH_ABSENT='SYNTHETIC-NEVER-PASSED-TO-THE-BANNER-943'
# A path inside this test's own sandbox rather than a home-shaped literal.
# The repo's PII-shape scanner matches on SHAPE, not on a list of known
# values, so even a plainly synthetic home path trips it -- correctly, and
# it caught this line before it was committed. The sandbox path is also the
# more honest fixture: it is where the run actually puts things.
SYNTH_SECRETS="${WORK}/synthetic-secrets"

echo "== the wiki credential is not gated on the wiki being ready (HR015 #943) =="
echo "   install.sh under test: ${SRC}"

# ── Extraction, with an explicit report of WHICH anchor was used ────────────
#
# Two anchors, because the fixed banner and the pre-fix one genuinely have
# different shapes and the mutation harness below has to be able to run this
# suite against either. The anchor actually used is printed, so a reader can
# never be left guessing which text was measured.

[ -r "${SRC}" ] || { cant "install.sh unreadable at ${SRC} -- NOTHING was examined"; echo; exit 2; }
[ -r "${STRINGS}" ] || { cant "strings catalogue unreadable at ${STRINGS}"; echo; exit 2; }

sentinel_open=$(grep -c '^# >>> wiki-handover-banner' "${SRC}")
sentinel_close=$(grep -c '^# <<< wiki-handover-banner' "${SRC}")
# -x -F: exact whole-line FIXED string. A BRE here would put an escaped "$"
# mid-pattern, which BSD and GNU grep do not agree about, and the anchor would
# silently find nothing on one of the two runners.
PREFIX_LINE='if [[ "$WIKI_FIRST_COMPILE_OK" == true ]]; then'
prefix_anchor=$(grep -c -x -F -- "${PREFIX_LINE}" "${SRC}")

ANCHOR=""
if [ "${sentinel_open}" = "1" ] && [ "${sentinel_close}" = "1" ]; then
    awk '/^# >>> wiki-handover-banner/{f=1} f{print} /^# <<< wiki-handover-banner/{f=0}' \
        "${SRC}" > "${WORK}/block.sh"
    ANCHOR="sentinels"
elif [ "${prefix_anchor}" = "1" ]; then
    awk -v anchor="${PREFIX_LINE}" \
        '$0 == anchor {f=1} f{print} f && $0 == "fi" {exit}' \
        "${SRC}" > "${WORK}/block.sh"
    ANCHOR="pre-fix if/fi"
else
    cant "no banner anchor in ${SRC} (sentinels open=${sentinel_open} close=${sentinel_close}, pre-fix if=${prefix_anchor}) -- NOTHING was examined"
    echo; exit 2
fi

block_lines=$(wc -l < "${WORK}/block.sh" | tr -d ' ')
echo "   extracted via ${ANCHOR}: ${block_lines} line(s)"
echo

if [ "${block_lines}" -lt 5 ]; then
    cant "the extracted banner is ${block_lines} line(s); that is not a banner, so nothing was measured"
    echo; exit 2
fi

# ── Harness ────────────────────────────────────────────────────────────────

{
    printf 'set -u\n'
    printf '# shellcheck disable=SC1090\n'
    printf 'source "${STRINGS}"\n'
    printf "BOLD=''; NC=''\n"
    cat "${WORK}/block.sh"
} > "${WORK}/harness.sh"

if ! bash -n "${WORK}/harness.sh" 2>"${WORK}/syntax.err"; then
    cant "the extracted banner does not parse: $(cat "${WORK}/syntax.err")"
    echo; exit 2
fi

# A pbcopy stub, so the suite never writes anything to a real clipboard and so
# the "clipboard succeeded" and "no pbcopy on this box" branches can BOTH be
# exercised on either runner.
mkdir -p "${WORK}/bin-with-pbcopy" "${WORK}/bin-without-pbcopy"
cat > "${WORK}/bin-with-pbcopy/pbcopy" <<'STUB'
#!/bin/sh
cat > /dev/null
STUB
chmod +x "${WORK}/bin-with-pbcopy/pbcopy"

# render <outfile> <pathdir> <VAR=VAL>...
render() {
    local out="$1" pathdir="$2"; shift 2
    env -i \
        PATH="${pathdir}" \
        STRINGS="${STRINGS}" \
        WIKI_PASSWORD="${SYNTH_PW}" \
        SECRETS_DIR="${SYNTH_SECRETS}" \
        OSTLER_WIKI_TAILNET_URL="" \
        "$@" \
        /bin/bash "${WORK}/harness.sh" > "${out}" 2>"${out}.err" 9>"${out}.fd9"
    local rc=$?
    if [ "${rc}" -ne 0 ]; then
        cant "the banner exited ${rc} for $*: $(head -3 "${out}.err")"
        return 2
    fi
    return 0
}

# The four states, rendered with NO pbcopy so the clipboard claim is out of the
# way for the credential limbs and gets its own two-branch limb at the end.
NOPB="${WORK}/bin-without-pbcopy"

render "${WORK}/ready.out"    "${NOPB}" WIKI_FIRST_COMPILE_OK=true  WIKI_PAGE_COUNT=412 _wiki_last_code=200 || true
render "${WORK}/building.out" "${NOPB}" WIKI_FIRST_COMPILE_OK=false WIKI_PAGE_COUNT=412 _wiki_last_code=000 || true
render "${WORK}/nopages.out"  "${NOPB}" WIKI_FIRST_COMPILE_OK=false WIKI_PAGE_COUNT=0   _wiki_last_code=000 || true
render "${WORK}/unknown.out"  "${NOPB}" WIKI_FIRST_COMPILE_OK=false                                        || true

for f in ready building nopages unknown; do
    [ -s "${WORK}/${f}.out" ] || cant "state '${f}' rendered NOTHING, so every limb reading it is vacuous"
done

# ── Limb 1: PREMISE, checked first. ────────────────────────────────────────
#
# Every credential limb below looks for a string INSIDE an output. If the
# outputs were empty they would all fail for the wrong reason, and if the
# search term were wrong they would all pass for the wrong reason. So the
# premise is asserted on the state that was ALWAYS correct, and the search
# predicate is given a negative control in the same limb.

# #2357: the password is handed to the customer on fd 9 (the terminal, saved
# before install.sh tees stdout into install.log) and NEVER on stdout, which is
# the log. So "the customer is given their password" reads the fd 9 channel,
# and a separate limb asserts it is absent from stdout.
if [ -s "${WORK}/ready.out" ] \
   && grep -qF "${SYNTH_PW}" "${WORK}/ready.out.fd9" \
   && grep -qF "localhost:8044" "${WORK}/ready.out"; then
    if grep -qF "${SYNTH_ABSENT}" "${WORK}/ready.out" "${WORK}/ready.out.fd9"; then
        bad "negative control: a value never handed to the banner was found in its output, so the search predicate is not reading what it claims"
    else
        ok "premise: the ready state renders the address and the password, and a value never passed in is NOT found"
    fi
else
    bad "premise: the ready state did not render the address and password, so limbs 2-4 would be vacuous"
fi

# ── Limbs 2-4: THE DEFECT. The sign-in is handed over in every state. ──────

for state in building nopages unknown; do
    out="${WORK}/${state}.out"
    [ -s "${out}" ] || continue
    if grep -qF "${SYNTH_PW}" "${out}.fd9"; then
        ok "state '${state}': the customer is given their password"
    else
        bad "state '${state}': NO password. This is the v1.0.98 experience -- the wiki finishes building later, serves, and asks for a credential the customer was never shown"
    fi
    if grep -qF "localhost:8044" "${out}"; then
        ok "state '${state}': the customer is given the wiki address"
    else
        bad "state '${state}': no address, so there is nothing for the sign-in to be used on"
    fi
done

# ── Limb 4b (#2357): the password never reaches stdout, which is install.log.
leaked=""
for state in ready building nopages unknown; do
    grep -qF "${SYNTH_PW}" "${WORK}/${state}.out" && leaked="${leaked} ${state}"
done
if [ -z "${leaked}" ]; then
    ok "no state prints the password on stdout, the stream install.sh tees into install.log"
else
    bad "the password is on stdout (so in install.log) in state(s):${leaked}"
fi

# ── Limb 5: THE ROUTE BACK. ────────────────────────────────────────────────
#
# Without this the clipboard is the only copy and it survives until the next
# thing the customer copies.

missing_route=""
for state in ready building nopages unknown; do
    out="${WORK}/${state}.out"
    [ -s "${out}" ] || continue
    grep -qF "${SYNTH_SECRETS}/wiki_password" "${out}" || missing_route="${missing_route} ${state}"
done
if [ -z "${missing_route}" ]; then
    ok "every state names where the password is kept on disk, so the clipboard is not the only copy"
else
    bad "no route back in state(s):${missing_route} -- the clipboard is the only copy and it is gone within minutes"
fi

# ── Limb 6: CONTROL OF THE SAME SHAPE. The three not-ready states must not ─
#            render the SAME readiness sentence.
#
# This is what stops the fix being "print everything, always". A banner that
# emitted one generic "not ready" line for all three would pass limbs 2 to 5
# and still leave the customer unable to tell a box that is building from one
# whose build produced nothing. Worse, it is the exact defect being fixed
# pointed the other way: one sentence asserted over three measured states.

if [ -s "${WORK}/building.out" ] && [ -s "${WORK}/nopages.out" ] && [ -s "${WORK}/unknown.out" ]; then
    b="$(cat "${WORK}/building.out")"; n="$(cat "${WORK}/nopages.out")"; u="$(cat "${WORK}/unknown.out")"
    if [ "${b}" != "${n}" ] && [ "${b}" != "${u}" ] && [ "${n}" != "${u}" ]; then
        ok "the three not-ready states each say something different, so a reader can tell which one this box is in"
    else
        bad "two or more not-ready states render identically: a still-building wiki and a build that produced nothing are reported as the same thing"
    fi
fi

# ── Limb 7: THE CAUSE NAMED MUST BE THE CAUSE MEASURED. ────────────────────
#
# Asserted as a verdict, not as a sentence: the still-building state may not
# claim a failure, and the ready state may not emit a readiness caveat at all.
# Its control is the zero-pages state, which IS a failure and is the only one
# permitted to read as one, proved by limb 6 requiring the two to differ.

if [ -s "${WORK}/building.out" ]; then
    if grep -qiE "fail(ed|ure)?" "${WORK}/building.out"; then
        bad "a wiki that is still building is reported to the customer as FAILED; on the v1.0.98 box it had not failed, it finished an hour later and worked"
    else
        ok "a wiki that is still building is not reported as a failure"
    fi
fi

if [ -s "${WORK}/ready.out" ] && [ -s "${WORK}/building.out" ]; then
    if [ "$(wc -l < "${WORK}/ready.out")" -lt "$(wc -l < "${WORK}/building.out")" ]; then
        ok "the ready state carries no readiness caveat, so a working wiki is not hedged at the customer"
    else
        bad "the ready state says as much about readiness as the building state, so the caveat is unconditional"
    fi
fi

# ── Limb 8: CLIPBOARD HONESTY, BOTH BRANCHES. ──────────────────────────────
#
# The claim "copied to your clipboard" must be made only when pbcopy actually
# succeeded. Both branches are exercised with a stub, so this limb runs the
# same way on macOS and on a Linux runner and neither one touches a real
# clipboard.

render "${WORK}/clip_yes.out" "${WORK}/bin-with-pbcopy:${PATH}" WIKI_FIRST_COMPILE_OK=true WIKI_PAGE_COUNT=412 _wiki_last_code=200 || true
if [ -s "${WORK}/clip_yes.out" ] && [ -s "${WORK}/ready.out" ]; then
    yes_claim=0; no_claim=0
    # The predicate is the CLAIM, not the word. The route-back line also
    # contains "clipboard" ("so the clipboard is not the only copy"), and a
    # bare word match scored that as a promise the installer had made. Caught
    # by this limb on its first run, which is the whole point of having it.
    grep -qF "Copied to your clipboard" "${WORK}/clip_yes.out" && yes_claim=1
    grep -qF "Copied to your clipboard" "${WORK}/ready.out"    && no_claim=1
    if [ "${yes_claim}" = "1" ] && [ "${no_claim}" = "0" ]; then
        ok "the clipboard is claimed when pbcopy succeeds and NOT claimed when pbcopy is absent"
    elif [ "${no_claim}" = "1" ]; then
        bad "the clipboard is claimed on a box with no pbcopy: a promise the installer did not keep"
    else
        bad "the clipboard is never claimed even when pbcopy succeeds, so the paste affordance is gone"
    fi
fi

echo
echo "PASS=${PASS} FAIL=${FAIL} CANNOT-RUN=${CANT}"

# ── Mutation harness ───────────────────────────────────────────────────────
#
# MUTANT A reinstates the defect by running every limb against install.sh as
# it stands on origin/main, extracted by its own pre-fix anchor. The suite must
# go RED. A guard that cannot be made to fail is not a guard.
#
# MUTANT B blinds the suite's own extractor: an install.sh with the sentinels
# stripped and no pre-fix anchor either. The suite must REFUSE (exit 2), not
# report a clean product. "We could not look" passing as "nothing is wrong" is
# the failure this whole row is about.

if [ "${SELF_TEST}" -eq 1 ]; then
    echo
    echo "== self-test: mutants =="
    SELF_PASS=0; SELF_FAIL=0; SELF_CANT=0

    # ── MUTANT A IS SYNTHESISED, NOT FETCHED ──────────────────────────────
    #
    # This used to materialise "the pre-fix install.sh" as
    # `git show origin/main:install.sh`. That worked for exactly as long as the
    # fix was unmerged. The moment it landed on main, the "before" state became
    # the "after" state, the mutant stopped failing, and this self-test went
    # red on every branch that took main. One moving reference, four PRs
    # blocked, and the guard reporting that it could not detect the defect it
    # was written for.
    #
    # A mutation must MUTATE THE CURRENT FILE. Re-introduce the defect instead:
    # the original shape put the whole credential handover inside
    # `if [[ "$WIKI_FIRST_COMPILE_OK" == true ]]`, so a box where that flag was
    # false got no address, no username and no password. Rebuilding that shape
    # from the file in front of us cannot rot, because it does not depend on
    # what any branch or remote currently holds.
    PREFIX_SH="${WORK}/install.prefix.sh"
    if [ -n "${OSTLER_PREFIX_REF:-}" ]; then
        # An explicit ref still works, for anyone bisecting a real commit.
        git -C "${REPO}" show "${OSTLER_PREFIX_REF}:install.sh" > "${PREFIX_SH}" 2>/dev/null || :
    else
        # Wrap the banner region in the flag it used to sit inside. awk, so the
        # sentinels are matched exactly and nothing outside them is touched.
        awk '
            /^# >>> wiki-handover-banner/ {
                print; print "if [[ \"$WIKI_FIRST_COMPILE_OK\" == true ]]; then"; next
            }
            /^# <<< wiki-handover-banner/ {
                print "fi"; print; next
            }
            { print }
        ' "${SRC}" > "${PREFIX_SH}"
    fi
    if [ -s "${PREFIX_SH}" ] \
       && ! cmp -s "${PREFIX_SH}" "${SRC}"; then
        set +e
        OSTLER_INSTALL_SH="${PREFIX_SH}" bash "${BASH_SOURCE[0]}" > "${WORK}/mutantA.out" 2>&1
        mrc=$?
        set -e
        # ── THE PROPERTY IS "THE MUTANT MUST NOT PASS", NOT "IT MUST EXIT 1" ──
        #
        # Re-introducing the defect makes the three not-ready states render
        # NOTHING, and this suite classifies an empty render as CANNOT-RUN
        # (exit 2) rather than FAIL (exit 1), because an empty render can also
        # mean the extractor broke. That classification is right for the real
        # product and wrong as a mutation expectation: exit 1 and exit 2 both
        # mean the guard REFUSED the defective input, and exit 0 is the only
        # answer that would prove it blind.
        #
        # Insisting on exit 1 here would fail the self-test for a mutant the
        # guard actually caught, which is a false alarm in the direction that
        # gets guards switched off.
        if [ "${mrc}" -ne 0 ]; then
            SELF_PASS=$((SELF_PASS+1))
            echo "  [PASS] MUTANT A: the defect re-introduced into THIS install.sh makes the suite refuse it (exit ${mrc}, and 0 is the only answer that would prove it blind)"
            grep -E '^\s+\[(FAIL|CANNOT-RUN)\]' "${WORK}/mutantA.out" | sed 's/^/         /'
        else
            SELF_FAIL=$((SELF_FAIL+1))
            echo "  [FAIL] MUTANT A: the mutated install.sh PASSED (exit 0). This guard does not detect the defect it was written for."
            tail -25 "${WORK}/mutantA.out" | sed 's/^/         /'
        fi
    else
        echo "  [CANNOT-RUN] MUTANT A: could not build a mutated install.sh, or it came out identical to the original -- the guard was NOT proved"
        SELF_CANT=$((SELF_CANT+1))
    fi

    BLIND_SH="${WORK}/install.blind.sh"
    grep -v -e '^# >>> wiki-handover-banner' -e '^# <<< wiki-handover-banner' \
        "${REPO}/install.sh" > "${BLIND_SH}"
    set +e
    OSTLER_INSTALL_SH="${BLIND_SH}" bash "${BASH_SOURCE[0]}" > "${WORK}/mutantB.out" 2>&1
    brc=$?
    set -e
    if [ "${brc}" -eq 2 ]; then
        SELF_PASS=$((SELF_PASS+1))
        echo "  [PASS] MUTANT B: with the sentinels stripped the suite REFUSES (exit 2) rather than passing"
    else
        SELF_FAIL=$((SELF_FAIL+1))
        echo "  [FAIL] MUTANT B: a blinded suite exited ${brc}, expected 2 CANNOT-RUN"
        tail -10 "${WORK}/mutantB.out" | sed 's/^/         /'
    fi

    echo
    echo "SELF-TEST PASS=${SELF_PASS} FAIL=${SELF_FAIL} CANNOT-RUN=${SELF_CANT}"
    [ "${SELF_FAIL}" -eq 0 ] || exit 1
    [ "${SELF_CANT}" -eq 0 ] || exit 2
fi

if [ "${FAIL}" -gt 0 ]; then
    exit 1
fi
if [ "${PASS}" -eq 0 ] || [ "${CANT}" -gt 0 ]; then
    exit 2
fi
exit 0
