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
#   scripts/post_walk_qa.sh andy@my-mini.local v1.0.38
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
OSTLER_BOX_HOST="$BOX" "${REPO_ROOT}/scripts/box_walk_probes/run_box_walk.sh"
probe_rc=$?
case "$probe_rc" in
    0) echo "  probes: clean" ;;
    1) echo "  probes: REAL FAILURES"; overall=1 ;;
    *) echo "  probes: coverage lost (cannot-run / broken)"
       [[ "$overall" -eq 0 ]] && overall=2 ;;
esac

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
    0) echo " RESULT: CLEAN WALK — everything ran and everything passed." ;;
    1) echo " RESULT: FAILED — at least one real defect on the box." ;;
    2) echo " RESULT: PARTIAL — nothing failed, but not everything ran."
       echo "         Coverage was LOST. Do not report this as a clean walk." ;;
esac
echo "   finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "════════════════════════════════════════════════════════════"
exit "$overall"
