#!/usr/bin/env bash
#
# POST-WALK QA — run this against a box the moment a DMG walk finishes.
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────
#
# Andy, 2026-08-21: "There's supposed to be something that runs automatically
# after a DMG test walk and checks everything."
#
# There wasn't. Searched OS003, CM051 and HR015 for "deep dive", "QA suite",
# "box walk", "acceptance": the only hits are a 2026-05-22 audit doc. What
# DOES exist is two harnesses that were never joined and were never invoked:
#
#   scripts/box_walk_probes/run_box_walk.sh   13 probes, four-count verdict
#   scripts/verify_cut_manifest.py            cut rows, --require-runtime-proofs
#
# #719: nothing invokes run_box_walk.sh at all. #713: every box_walk_probe
# manifest row had ALWAYS returned SKIP, and SKIP does not fail a cut. So the
# suite was not missing — it was BUILT AND DARK, which is this project's most
# frequent defect shape and the reason a human kept finding things by hand.
#
# This is the join. One command, one box, four counts, non-zero exit if the
# walk was not clean.
#
# ── USAGE ────────────────────────────────────────────────────────────────
#
#   scripts/post_walk_qa.sh <box-host> [cut-version]
#
#   scripts/post_walk_qa.sh andy@192.0.2.10
#   scripts/post_walk_qa.sh <user>@<hub-host> v1.0.38
#
# <box-host> is anything ssh accepts. It is REQUIRED and there is deliberately
# no default: a suite that silently falls back to "this machine" is how the
# installed-bundle-seal probe ran its self-test on the wrong computer, found no
# Ostler bundles, and reported BROKEN instead of a verdict.
#
# ── WHAT "CLEAN" MEANS, AND WHAT IT DOES NOT ─────────────────────────────
#
# FOUR counts, never one:
#   PASS        measured, and the measurement was good
#   FAIL        measured, and the measurement was bad          -> exit 1
#   CANNOT-RUN  a prerequisite was absent; NOT a pass          -> exit 2
#   BROKEN      the probe failed its own negative control      -> exit 2
#
# A run with 0 FAIL and 5 CANNOT-RUN is NOT a clean walk; it is a partial one,
# and this script says so and exits non-zero. Coverage lost is not coverage
# passed. That distinction is the whole reason the box walk exists.
#
# EXIT CODES
#   0  every probe ran and passed, and the manifest rows agree
#   1  at least one real FAIL
#   2  at least one CANNOT-RUN or BROKEN (coverage lost), no hard FAIL
#   3  usage / could not reach the box at all
#
# ⚠️ THE PROBE SUITE WRITES. people_seed_and_retrieval seeds a synthetic person
# into the LIVE store and removes it on the happy path only (#829). Do not run
# this against a box you are mid-demo on.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOX="${1:-}"
CUT_VERSION="${2:-}"

if [[ -z "$BOX" ]]; then
    cat >&2 <<'USAGE'
usage: scripts/post_walk_qa.sh <box-host> [cut-version]

  <box-host>     ssh target of the box that was just walked (REQUIRED)
  [cut-version]  e.g. v1.0.38 -- also re-drives the cut manifest's runtime
                 proofs against that box. Omit to run the probes only.

No default host by design: a QA suite that quietly measures the wrong machine
is worse than one that refuses to run.
USAGE
    exit 3
fi

echo "════════════════════════════════════════════════════════════"
echo " POST-WALK QA"
echo "   box     : ${BOX}"
echo "   cut     : ${CUT_VERSION:-(probes only, no manifest rows)}"
echo "   started : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "════════════════════════════════════════════════════════════"

# Reachability first, and as its own outcome. Without this, every probe
# independently reports CANNOT-RUN and the summary reads like 13 separate
# defects instead of one unplugged cable.
if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" 'true' 2>/dev/null; then
    echo
    echo "CANNOT REACH ${BOX} over ssh."
    echo "Nothing was measured. This is not a pass and not a failure -- it is"
    echo "no data. Check the host, then re-run."
    exit 3
fi
echo "  ssh to ${BOX}: OK"

overall=0

echo
echo "──── 1. BOX-WALK PROBES ────────────────────────────────────"
echo "     (phase 1 runs each probe's negative control BEFORE trusting"
echo "      any phase 2 measurement -- a probe that cannot fail is BROKEN)"
echo
# Output is CAPTURED, not just streamed, because the counts are needed twice:
# once for the verdict here and once for the walk record at the end. The suite
# is NOT run a second time to get them -- people_seed_and_retrieval writes a
# synthetic person into the LIVE store (#829), so a second run is a second
# write, and a second chance to leave the seed behind.
# THE LOG SURVIVES THE RUN. It used to be `mktemp` + `trap rm EXIT`, so the
# moment the walk finished the only record of WHICH probes failed was deleted.
#
# MEASURED 2026-08-26: walks/v1.0.47.tsv says fail=5 cannot_run=4 verdict=FAILED
# and names not one probe. The counts gate the customer download; the detail
# that would let anyone ACT on them was destroyed by this script. The only way
# back to it is to re-walk a physical box, which is the most expensive step we
# have. A gate that refuses a cut and then discards its reasons makes the
# refusal unactionable.
#
# NOT IN THE REPO, DELIBERATELY. This repo is PUBLIC, which is the whole reason
# the walk record stores the box as a hash (box_fp) rather than a hostname. The
# raw probe log is the opposite: real hostname, real paths, real output. It goes
# to the operator's own machine and never becomes a tracked file. Do not "helpfully"
# move this under walks/.
#
# If the durable path cannot be created we fall back to mktemp and SAY SO,
# rather than silently returning to the old behaviour.
PROBE_LOG=""
_walk_logdir="${HOME}/.ostler/walks"
if mkdir -p "$_walk_logdir" 2>/dev/null; then
    PROBE_LOG="${_walk_logdir}/${CUT_VERSION:-unversioned}-$(date -u +%Y%m%dT%H%M%SZ).log"
    : > "$PROBE_LOG" 2>/dev/null || PROBE_LOG=""
fi
if [[ -z "$PROBE_LOG" ]]; then
    PROBE_LOG="$(mktemp)"
    trap 'rm -f "$PROBE_LOG"' EXIT
    echo "  ⚠️ could not write ${_walk_logdir}; probe detail is TEMPORARY and dies with this run"
else
    # THE LOG NAMES THE BOX IN PLAINTEXT. The walk record cannot: it stores
    # sha256(host)[0:16], because it is committed to a PUBLIC repo.
    #
    # That hashing is right, and it also means NOBODY can recover which machine
    # a walk ran against -- including the operator. Measured today: v1.0.47's
    # record says box_fp 38abe713e160f279 and eleven candidate hosts hashed to
    # none of them, so the box behind a FAILED verdict is simply unknown.
    #
    # This file is operator-local and never tracked, so it is the correct place
    # for the plaintext. Public record: hash. Local log: host. Both true, and
    # only one of them leaves the machine.
    {
        printf '# ostler box walk\n'
        printf '# host      %s\n' "$BOX"
        printf '# box_fp    %s\n' "$(printf '%s' "$BOX" | shasum -a 256 | cut -c1-16)"
        printf '# version   %s\n' "${CUT_VERSION:-(none given)}"
        printf '# started   %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '#\n'
    } > "$PROBE_LOG"
    echo "  probe detail will be kept at: ${PROBE_LOG}"
fi
OSTLER_BOX_HOST="$BOX" "${REPO_ROOT}/scripts/box_walk_probes/run_box_walk.sh" 2>&1 | tee -a "$PROBE_LOG"
probe_rc="${PIPESTATUS[0]}"

# THE COUNTS, NOT THE RETURN CODE. run_box_walk.sh exits 0 whenever
# FAIL == 0 && BROKEN == 0 -- so a walk where five probes never ran returns
# the same 0 as a walk where fourteen passed. This file's own header promises
# that a partial walk "exits non-zero", and until the counts were read that
# promise could not be kept: the verdict was invariant to coverage loss, the
# one distinction the box walk exists to make.
count_of() { awk -v k="$1" '$1 == k { print $2; exit }' "$PROBE_LOG"; }
n_pass="$(count_of PASS)";       n_fail="$(count_of FAIL)"
n_cannot="$(count_of CANNOT-RUN)"; n_broken="$(count_of BROKEN)"
for v in n_pass n_fail n_cannot n_broken; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' ""
done

if [[ -z "$n_pass$n_fail$n_cannot$n_broken" ]]; then
    # The summary block could not be parsed at all. That is CANNOT-RUN for
    # this script, not a pass for the box: fall back to the rc and say so.
    echo "  probes: could not parse the summary block -- falling back to rc=${probe_rc}"
    echo "  ⚠️ COUNTED AS COVERAGE LOST. A verdict nobody could read is not a clean one."
    [[ "$probe_rc" -ne 0 ]] && overall=1 || overall=2
elif [[ "${n_fail:-0}" -gt 0 || "${n_broken:-0}" -gt 0 ]]; then
    echo "  probes: REAL FAILURES (fail=${n_fail:-0} broken=${n_broken:-0})"
    overall=1
elif [[ "${n_cannot:-0}" -gt 0 ]]; then
    echo "  probes: coverage lost (cannot-run=${n_cannot})"
    echo "  ⚠️ run_box_walk.sh returned ${probe_rc} for this, which is why the"
    echo "     counts are read rather than the exit code."
    [[ "$overall" -eq 0 ]] && overall=2
else
    echo "  probes: clean (pass=${n_pass})"
fi

if [[ -n "$CUT_VERSION" ]]; then
    echo
    echo "──── 2. CUT MANIFEST, RUNTIME PROOFS ───────────────────────"
    echo "     (these rows returned SKIP on every cut before #713 -- SKIP is"
    echo "      not a pass, so they are driven against the real box here)"
    echo
    if [[ -f "${REPO_ROOT}/cut-manifests/${CUT_VERSION}.yaml" ]]; then
        # --version, NOT a positional. The first version of this line passed
        # the version positionally, argparse rejected it, and the script
        # reported "manifest: rows FAILED" -- a usage error dressed up as a
        # product defect. Caught by running it against a real box, which is
        # the only reason it is not still in here.
        OSTLER_BOX_HOST="$BOX" python3 "${REPO_ROOT}/scripts/verify_cut_manifest.py" \
            --version "$CUT_VERSION" --require-runtime-proofs
        manifest_rc=$?
        if [[ "$manifest_rc" -ne 0 ]]; then
            echo "  manifest: rows FAILED"
            overall=1
        else
            echo "  manifest: all rows satisfied"
        fi
    else
        echo "  no cut-manifests/${CUT_VERSION}.yaml -- skipping manifest rows."
        echo "  ⚠️ COUNTED AS COVERAGE LOST, not as a pass."
        [[ "$overall" -eq 0 ]] && overall=2
    fi
fi

echo
echo "════════════════════════════════════════════════════════════"
case "$overall" in
    0) VERDICT=CLEAN;   echo " RESULT: CLEAN WALK — everything ran and everything passed." ;;
    1) VERDICT=FAILED;  echo " RESULT: FAILED — at least one real defect on the box." ;;
    2) VERDICT=PARTIAL; echo " RESULT: PARTIAL — nothing failed, but not everything ran."
       echo "         Coverage was LOST. Do not report this as a clean walk." ;;
esac
echo "   finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "════════════════════════════════════════════════════════════"

# ── WRITE THE WALK RECORD (#844) ─────────────────────────────────────────
#
# Running this suite proved nothing about the release until the result could
# be CONSULTED. #844: nothing between "gates green" and "customer download"
# was a runtime proof, because the only runtime proof there is lived in a
# terminal that got closed. scripts/verify_walk_record.sh reads this file and
# scripts/publish_release.sh refuses to repoint ostler.ai/install.dmg without
# a CLEAN one for the exact version being published.
#
# Only written when a cut version was named: a probes-only run is a useful
# spot-check but it is not evidence about a release, and writing a record for
# "" would create a file that clears a gate for nothing.
if [[ -n "$CUT_VERSION" ]]; then
    WALK_DIR="${OSTLER_WALK_RECORD_DIR:-${REPO_ROOT}/walks}"
    mkdir -p "$WALK_DIR"
    RECORD="${WALK_DIR}/${CUT_VERSION}.tsv"

    # THE HOST IS HASHED, NEVER RECORDED. This repo is PUBLIC and $BOX is an
    # ssh target -- routinely user@address. Writing it raw would commit an
    # operator's account name and their machine's address on every walk. The
    # hash still distinguishes "walked twice on the same box" from "walked on
    # two boxes", which is the only thing the field is for.
    BOX_FP="$(printf '%s' "$BOX" | shasum -a 256 | cut -c1-16)"

    # ── 🔴 THE VERSION MUST BE MEASURED, NOT ACCEPTED ─────────────────────
    #
    # This file gates the customer download. Until 2026-08-24 it recorded the
    # version it was TOLD -- `CUT_VERSION="${2:-}"`, written straight through --
    # and verified nothing. So a walk record could attribute real measurements
    # taken on a real box to a version that box had never run.
    #
    # It did. walks/v1.0.42.tsv says `version v1.0.42, walked_at
    # 2026-08-23T16:35:28Z, fail 4`. v1.0.42 was never installed anywhere by
    # anyone. The box held v1.0.38 -- its ~/Downloads DMG is 57,818,336 bytes,
    # the published v1.0.38 count, and the box carried exactly one install.sh
    # run header, from 21 Aug. I passed the wrong argument and the register
    # wrote it down without comment.
    #
    # A control proves your predicate, never your specimen. So: read the cut
    # version off the box and refuse to write a record that disagrees with it.
    # version_source records HOW the value was obtained, so a reader can tell a
    # measured version from an unverifiable one.
    #
    # 🔴 READ THE RIGHT BUNDLE. Three surfaces on a walked box carry a version
    # and only ONE of them is the cut. Measured on the Mini 2026-08-24:
    #
    #   /Applications/OstlerInstaller.app   1.0.43        <- THE CUT. Use this.
    #   /Applications/Ostler.app            0.7.1         hub app's own version
    #   ~/.ostler/VERSION                   hub-v0.4.61   the daemon, and stale
    #
    # The first draft of this block read Ostler.app and would have compared
    # "1.0.43" against "0.7.1" -- refusing every legitimate walk record while
    # looking like a rigorous check. A guard watching the wrong object is not a
    # weaker guard, it is a differently-wrong one.
    #
    # OstlerInstaller.app records which installer RAN, not whether it
    # succeeded. That is correct for this field: `version` says what was
    # walked; `verdict` and `fail` say how it went.
    INSTALLED_VERSION="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
        '/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
             /Applications/OstlerInstaller.app/Contents/Info.plist 2>/dev/null' 2>/dev/null \
        | tr -d '[:space:]')"

    if [[ -z "$INSTALLED_VERSION" ]]; then
        VERSION_SOURCE="asserted-unverifiable(no Ostler.app on box)"
        RECORDED_VERSION="$CUT_VERSION"
        echo "  ⚠️  could not read an installed version off ${BOX}."
        echo "      Recording version_source=${VERSION_SOURCE} -- a reader must NOT"
        echo "      treat this record's version as measured."
    elif [[ -z "$CUT_VERSION" ]]; then
        VERSION_SOURCE="measured(CFBundleShortVersionString)"
        RECORDED_VERSION="v${INSTALLED_VERSION#v}"
        echo "  version derived from the box: ${RECORDED_VERSION}"
    elif [[ "${CUT_VERSION#v}" == "${INSTALLED_VERSION#v}" ]]; then
        VERSION_SOURCE="measured(CFBundleShortVersionString, matches argument)"
        RECORDED_VERSION="$CUT_VERSION"
    else
        echo >&2
        echo "🔴 REFUSING TO WRITE THE WALK RECORD -- VERSION MISMATCH." >&2
        echo "   argument says : ${CUT_VERSION}" >&2
        echo "   the box says  : v${INSTALLED_VERSION#v}  (CFBundleShortVersionString)" >&2
        echo >&2
        echo "   This is the walks/v1.0.42.tsv mistake. Real measurements would be" >&2
        echo "   filed against a version this box has never run, in the file that" >&2
        echo "   gates the customer download." >&2
        echo >&2
        echo "   Re-run with the version the box actually holds, or with no version" >&2
        echo "   argument at all and let it be measured. NOT a failure of the walk --" >&2
        echo "   nothing was measured wrongly, only labelled wrongly. Exit 3." >&2
        exit 3
    fi

    # Counts are the ones already parsed from the single probe run above --
    # the suite is deliberately not re-invoked. See the note at that call.
    {
        printf '# Ostler walk record -- written by scripts/post_walk_qa.sh\n'
        printf '# Read by scripts/verify_walk_record.sh, which gates the customer download.\n'
        printf '# The box is recorded as a hash: this repo is public.\n'
        printf '# version_source says how the version was obtained. Anything other than\n'
        printf '# measured(...) means the version is an assertion, not an observation.\n'
        printf '#\n'
        printf '# counts_scope says WHICH population pass/fail/cannot_run/broken describe.\n'
        printf '# They are phase 1 ONLY -- parsed from run_box_walk.sh. Phase 2 (the cut\n'
        printf '# manifest runtime proofs) contributes to verdict and qa_exit but emits no\n'
        printf '# counts, so it is deliberately absent from these four numbers.\n'
        printf '# READ verdict AND qa_exit FOR THE WHOLE-SUITE RESULT. The four counts are\n'
        printf '# a subset and summing them will not reconcile against the console tally --\n'
        printf '# 2026-08-24 that mismatch (13 here vs 33 on console) was carried for hours\n'
        printf '# as an unexplained discrepancy in a v1.0.44 verdict that was correct all\n'
        printf '# along, because these keys were unqualified.\n'
        printf 'version\t%s\n'        "$RECORDED_VERSION"
        printf 'version_source\t%s\n' "$VERSION_SOURCE"
        printf 'walked_at\t%s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'box_fp\t%s\n'      "$BOX_FP"
        printf 'counts_scope\tbox_walk_probes_only(phase1); verdict+qa_exit cover all phases\n'
        printf 'pass\t%s\n'        "${n_pass:-0}"
        printf 'fail\t%s\n'        "${n_fail:-0}"
        printf 'cannot_run\t%s\n'  "${n_cannot:-0}"
        printf 'broken\t%s\n'      "${n_broken:-0}"
        printf 'verdict\t%s\n'     "$VERDICT"
        printf 'qa_exit\t%s\n'     "$overall"
    } > "$RECORD"

    echo
    echo "  walk record written: ${RECORD}"
    if [[ "$overall" -eq 0 ]]; then
        echo "  ⚠️  COMMIT IT. The customer download for ${CUT_VERSION} stays pointed at"
        echo "      the PREVIOUS release until this file is on main:"
        echo "          git add ${RECORD#"${REPO_ROOT}/"} && git commit"
    else
        echo "  This record is NOT clean, so it will not release ${CUT_VERSION} to customers."
        echo "  Fix the box, re-walk, and let it overwrite this file."
    fi
fi

exit "$overall"
