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
#   scripts/box_walk_probes/run_box_walk.sh   every probe in probes/, four-count verdict
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

# WHICH PROBES ARE ABOUT TO GRADE THIS ARTEFACT.
#
# Resolved once, here, so the value in the record is the tree that actually ran
# rather than whatever the checkout looks like minutes later. Same idiom as
# version / version_source: the value, and how it was obtained, so a reader is
# never left inferring from an absent field.
#
# THREE OUTCOMES, and the third is the one that matters. A commit id that does
# not describe the probes that ran is worse than none, because it looks
# authoritative. Local edits under box_walk_probes are named.
_resolve_instrument_rev() {
    local _sha _rc=0 _dirty
    if ! command -v git >/dev/null 2>&1; then
        INSTRUMENT_REV="unavailable"
        INSTRUMENT_SOURCE="unavailable(git not on PATH)"
        return 0
    fi
    _sha="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || _rc=$?
    if [ "$_rc" -ne 0 ] || [ -z "$_sha" ]; then
        INSTRUMENT_REV="unavailable"
        INSTRUMENT_SOURCE="unavailable(not a git checkout, or rev-parse rc=${_rc})"
        return 0
    fi
    INSTRUMENT_REV="$_sha"
    _dirty="$(git -C "$REPO_ROOT" status --porcelain -- scripts/box_walk_probes 2>/dev/null | /usr/bin/grep -c . || true)"
    if [ "${_dirty:-0}" -gt 0 ]; then
        INSTRUMENT_SOURCE="measured(git rev-parse HEAD) WITH ${_dirty} UNCOMMITTED change(s) under scripts/box_walk_probes -- the sha does NOT describe the probes that ran"
    else
        INSTRUMENT_SOURCE="measured(git rev-parse HEAD, scripts/box_walk_probes clean)"
    fi
}
_resolve_instrument_rev
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

# ── 🔴 A VERSION TYPO IS NOT A MISSING MANIFEST ─────────────────────────
#
# MEASURED 2026-09-05. Driving the manifest branch directly:
#
#   1.0.71   -> "no cut-manifests/1.0.71.yaml"   COVERAGE LOST   overall=2
#   v9.9.99  -> "no cut-manifests/v9.9.99.yaml"  COVERAGE LOST   overall=2
#
# Identical state, and they are DIFFERENT FINDINGS. One is a cut with no
# manifest, which must block a promote. The other is an operator who typed
# the name wrong while the manifest sits on disk under its real name.
# Reporting the second as "coverage lost" hides a manifest that is present.
#
# It is malformed input, not absence: all 59 cut manifests are named
# v<N.N.N>.yaml and 0 are named without the leading v, so a bare 1.0.71
# cannot match a real file under any circumstances.
#
# IT ALSO FAILED LATE. This check sat AFTER the ssh and after the probe
# suite, and that suite WRITES to the live store (see the warning above).
# A typo therefore cost a full box walk before the operator learned the
# argument was wrong. The refusal now happens before anything runs.
#
# Deliberately looser than the observed names: leading v plus a dotted
# numeric body, so a future 4-component version is not falsely refused.
# The leading v is the load-bearing part, because that is what the real
# typo dropped.
if [[ -n "$CUT_VERSION" && ! "$CUT_VERSION" =~ ^v[0-9]+(\.[0-9]+)+$ ]]; then
    {
        echo "usage: cut-version must look like v1.0.38, not '${CUT_VERSION}'."
        if [[ -f "${REPO_ROOT}/cut-manifests/v${CUT_VERSION}.yaml" ]]; then
            echo
            echo "  cut-manifests/v${CUT_VERSION}.yaml EXISTS -- you are one"
            echo "  leading 'v' away. Re-run with: v${CUT_VERSION}"
        fi
        echo
        echo "Refusing before the probe suite runs, because that suite WRITES to"
        echo "the live store. This is a usage error, exit 3. It is NOT the same"
        echo "as a missing manifest, which is a coverage finding and exits 2."
    } >&2
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
# THE SUMMARY LINE, NOT THE FIRST LINE THAT STARTS WITH THE WORD.
#
# This was `awk '$1 == k {print $2; exit}'` and it under-reported BROKEN to ZERO
# on every walk that had one.
#
# PASS / FAIL / CANNOT-RUN appear ONLY in the closing summary, so they parsed by
# luck. BROKEN is also a PER-PROBE LABEL in phase 1 -- "BROKEN  <name>  (self-test
# returned 0, expected 1)" -- and phase 1 comes first. So the match landed on the
# probe line, returned the probe's NAME as the count, failed the ^[0-9]+$ guard
# below, and was coerced to empty, which reads downstream as 0.
#
# MEASURED on the 2026-08-26T14:17:14Z walk of andy@192.168.1.228:
#     line  20  BROKEN   app_signature_survives_first_run  (...)   <- matched this
#     line 206  BROKEN      2                                      <- meant this
#     count_of BROKEN -> "app_signature_survives_first_run" -> record wrote 0
#
# BROKEN is the most serious state the suite has: a probe that fails its own
# negative control is measuring NOTHING, and phase 2 skips it. It was the one
# count that read zero exactly when it mattered, in the record that gates the
# customer download. Two probes were broken that run and the record said none.
#
# THE DISCRIMINATOR IS SHAPE, NOT POSITION. Summary lines are exactly two fields
# with a numeric second field. Per-probe lines carry the name and a parenthetical,
# so they are 7 or 13 fields. Anchoring on "NF == 2 && $2 is a number" cannot be
# fooled by a probe whose name happens to sort earlier, and does not depend on
# the summary staying at the bottom.
count_of() { awk -v k="$1" '$1 == k && NF == 2 && $2 ~ /^[0-9]+$/ { print $2; exit }' "$PROBE_LOG"; }
n_pass="$(count_of PASS)";       n_fail="$(count_of FAIL)"
n_cannot="$(count_of CANNOT-RUN)"; n_broken="$(count_of BROKEN)"
for v in n_pass n_fail n_cannot n_broken; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" '%s' ""
done

# THE DENOMINATOR, WHICH count_of CANNOT REACH.
#
# The runner closes with
#     of          21 probes
# which is THREE fields, so the NF==2 anchor above skips it by construction. It
# needs its own shape anchor rather than a loosened one: widening count_of to
# NF>=2 would let a per-probe line back in, which is the exact defect the NF==2
# rule was added to kill.
#
# Empty is left empty. A fabricated denominator is worse than an absent one --
# it would let the coverage line below state a ratio nobody measured.
n_probes="$(awk '$1 == "of" && NF == 3 && $2 ~ /^[0-9]+$/ && $3 == "probes" { print $2; exit }' "$PROBE_LOG")"
[[ "$n_probes" =~ ^[0-9]+$ ]] || n_probes=""

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
    # PREFER WHAT THE WALK SAYS IT RAN, over what happens to be in /Applications.
    #
    # 🔴 MEASURED 2026-09-04, v1.0.66 artefact walk. This gate refused to write
    # a record:
    #
    #     argument says : v1.0.66
    #     the box says  : v1.0.63  (CFBundleShortVersionString)
    #
    # The box was not lying. An ARTEFACT walk mounts the DMG and runs the
    # install.sh INSIDE it -- nothing is ever dragged to /Applications -- so
    # that path held an app a DIFFERENT run had left 13 hours earlier. The
    # DMG's own bundle was correctly stamped 1.0.66/6600.
    #
    # The comment below is right that this field means "which installer RAN".
    # On an artefact walk, /Applications cannot answer that question, and
    # reading it there is a guard watching the wrong object -- the exact
    # failure the note about 1.0.43-vs-0.7.1 already warns of, one object over.
    #
    # ttywalk.sh --from-dmg now writes ~/.walk-artefact-version from the bundle
    # it mounted. A repo walk leaves it EMPTY, so the /Applications fallback is
    # unchanged for every GUI walk, which is the flow that path was written for.
    # STORE PROVENANCE. ttywalk.sh's reset step already SAYS, in its own output,
    # that the graph, the vectors and the compiled wiki are carried over from the
    # previous install and that "any probe reading them is measuring history, not
    # this artefact". MEASURED 2026-09-05: that sentence was repeated NOWHERE
    # downstream -- 0 mentions across the probes, this file and
    # verify_walk_record.sh, against a control of 24 of 24 probes naming
    # probe_cannot_run. So a probe that failed on carried-over data arrived in
    # the record as evidence about the DMG, with nothing to say otherwise.
    #
    # An unreadable marker is recorded as unknown(...), never as a clean value.
    # An assumption here would be indistinguishable from a measurement.
    STORES_PROVENANCE="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
        'cat ~/.walk-stores-provenance 2>/dev/null' 2>/dev/null | tr -d '[:space:]')"
    case "$STORES_PROVENANCE" in
        carried-over-from-previous-install|unknown-no-reset-step|wiped-by-shipped-uninstaller*|wiped-by-explicit-store-wipe*) : ;;
        '') STORES_PROVENANCE="unknown(no ~/.walk-stores-provenance on the box; this walk predates the marker or the read failed)" ;;
        *)  STORES_PROVENANCE="unknown(marker held an unrecognised value)" ;;
    esac
    echo "  stores: ${STORES_PROVENANCE}"

    INSTALLED_VERSION="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
        'cat ~/.walk-artefact-version 2>/dev/null' 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$INSTALLED_VERSION" ]]; then
        echo "  version source: the walk's own record of the bundle it ran (~/.walk-artefact-version)"
    else
        INSTALLED_VERSION="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
            '/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
                 /Applications/OstlerInstaller.app/Contents/Info.plist 2>/dev/null' 2>/dev/null \
            | tr -d '[:space:]')"
    fi

    # A VERSION IS A SHAPE, NOT MERELY A NON-EMPTY STRING.
    #
    # PlistBuddy writes its failure to STDOUT, so `2>/dev/null` cannot suppress
    # it and the message survives `tr -d '[:space:]'` as one long token. It is
    # NON-EMPTY, so the -z check below passed and the string travelled on as a
    # version.
    #
    # With a CUT_VERSION argument that fails closed: the comparison mismatches
    # and the script refuses at exit 3. WITHOUT one -- which this script
    # explicitly invites, "or with no version argument at all and let it be
    # measured" -- the elif below records it as
    # version_source=measured(CFBundleShortVersionString), which is the one
    # thing that field exists to promise.
    #
    # Same fix as ttywalk.sh:346 and CM051 #1500/#1524: validate the shape.
    if [[ -n "$INSTALLED_VERSION" && ! "$INSTALLED_VERSION" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; then
        echo "  ⚠️  the box returned something that is not a version; discarding it." >&2
        INSTALLED_VERSION=""
    fi

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

    # ── 🔴 ...AND A VERSION IS NOT AN IDENTIFIER OF A BUILD (#931) ────────
    #
    # Everything above measures the version harder. It cannot measure it more
    # USEFULLY, because the version does not distinguish builds of one cut:
    # CFBundleShortVersionString read "1.0.50" for eleven distinct assemblies,
    # and CFBundleVersion was frozen at 2500 for seven cuts (#703). Rigour
    # applied to the wrong quantity buys epistemic status, not discrimination.
    #
    # So record a CONTENT HASH of the artefact this box was walked with, and
    # let verify_walk_record.sh compare it to the sha256 of the file about to
    # be published. That is the only pair of values in the gate where both
    # sides are content.
    #
    # 🔴 STATE THE RESIDUAL, DO NOT BURY IT. The strongest thing reachable from
    # here is "a DMG named for this version is present on the walked box and
    # hashes to X". That is NOT proof it is the DMG that was opened: a file in
    # ~/Downloads may never have been mounted. What it does do -- and what the
    # version field cannot -- is discriminate between builds. An operator who
    # downloads a second build of the same version onto the box makes the field
    # ambiguous, and ambiguity is recorded as ambiguity below, never guessed.
    #
    # The value is written on every path so a reader is never left inferring
    # from an absent field; artefact_sha256_source says which path was taken,
    # and the gate refuses anything that is not measured(...).
    ARTEFACT_SHA="unavailable"
    ARTEFACT_SHA_SOURCE="asserted-unverifiable(not attempted)"

    _dmg_err="$(mktemp)"
    _dmg_list="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
        'for d in "$HOME/Downloads" "$HOME/Desktop" "$HOME"; do
             [ -d "$d" ] && find "$d" -maxdepth 1 -type f -name "OstlerInstaller-*.dmg" -print
         done' 2>"$_dmg_err")"
    _dmg_rc=$?
    _dmg_stderr="$(cat "$_dmg_err")"
    rm -f "$_dmg_err"

    # A non-zero rc here is CANNOT-MEASURE, and its stderr is a diagnostic, not
    # a file list. Reading it as one is how rc=127 becomes a body.
    if [[ "$_dmg_rc" -ne 0 ]]; then
        ARTEFACT_SHA_SOURCE="asserted-unverifiable(box unreachable or find failed, rc=${_dmg_rc})"
        echo "  ⚠️  could not look for the walked DMG on ${BOX} (rc=${_dmg_rc})."
        [[ -n "$_dmg_stderr" ]] && echo "      ${_dmg_stderr}"
    else
        _want="OstlerInstaller-${CUT_VERSION#v}.dmg"
        # grep -F: the pattern is a literal filename. -c is not used for the
        # decision because the empty-list case must count 0, not error.
        _matched="$(printf '%s\n' "$_dmg_list" | /usr/bin/grep -F -- "/${_want}")"
        _n_matched="$(printf '%s' "$_matched" | /usr/bin/grep -c .)"
        [[ -z "$_matched" ]] && _n_matched=0

        if [[ "$_n_matched" -eq 1 ]]; then
            _hash="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$BOX" \
                "shasum -a 256 -- '${_matched}'" | awk '{print $1}')"
            if [[ "$_hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
                ARTEFACT_SHA="$_hash"
                ARTEFACT_SHA_SOURCE="measured(shasum -a 256 of ${_want} on the walked box; presence, not proof of mount)"
                echo "  artefact hashed on the box: ${_hash}"
            else
                ARTEFACT_SHA_SOURCE="asserted-unverifiable(shasum on the box returned no usable digest)"
                echo "  ⚠️  ${_want} is on ${BOX} but shasum returned nothing usable."
            fi
        elif [[ "$_n_matched" -eq 0 ]]; then
            ARTEFACT_SHA_SOURCE="asserted-unverifiable(no ${_want} on the box)"
            echo "  ⚠️  no ${_want} found on ${BOX}. The walk is real; which BUILD it"
            echo "      walked cannot be established from here."
        else
            ARTEFACT_SHA_SOURCE="asserted-unverifiable(${_n_matched} copies of ${_want} on the box, cannot tell which was installed)"
            echo "  ⚠️  ${_n_matched} copies of ${_want} on ${BOX}. Ambiguous, so recorded"
            echo "      as ambiguous rather than guessed."
        fi
    fi

    # Counts are the ones already parsed from the single probe run above --
    # the suite is deliberately not re-invoked. See the note at that call.
    # WHICH PROBES FAILED, NOT JUST HOW MANY.
    #
    # run_box_walk.sh already prints the names, under "FAILED:", "NOT MEASURED"
    # and "BROKEN". They were reaching a mktemp PROBE_LOG that this script
    # deletes on EXIT, while only the four counts were lifted into the record.
    # So the gate that decides whether customers get a build recorded `fail 5`
    # and nothing that could say which five. Two days after the v1.0.44 walk,
    # `fail 5` was the whole of what survived it.
    #
    # NAMES ONLY, never a probe's output. A probe's stdout carries paths and
    # hostnames, and this repo is public -- which is why box_fp is a hash. The
    # names are filenames under scripts/box_walk_probes/probes/ and carry
    # nothing about the box. The pattern below accepts only that shape, so a
    # line that is not a bare probe name is dropped rather than published.
    section_names() { # $1 = leading text of the section header
        awk -v hdr="$1" '
            index($0, hdr) == 1 { grab = 1; next }
            grab && $0 ~ /^[[:space:]]*$/ { exit }
            grab && $0 ~ /^  [A-Za-z0-9._-]+$/ { sub(/^  /, ""); print; next }
            grab { exit }
        ' "$PROBE_LOG"
    }
    FAILED_NAMES="$(section_names 'FAILED:')"
    NOTMEAS_NAMES="$(section_names 'NOT MEASURED')"
    BROKEN_NAMES="$(section_names 'BROKEN (')"
    n_failed_named="$(printf '%s' "$FAILED_NAMES" | grep -c . || true)"

    {
        printf '# Ostler walk record -- written by scripts/post_walk_qa.sh\n'
        printf '# Read by scripts/verify_walk_record.sh, which gates the customer download.\n'
        printf '# The box is recorded as a hash: this repo is public.\n'
        printf '# version_source says how the version was obtained. Anything other than\n'
        printf '# measured(...) means the version is an assertion, not an observation.\n'
        printf '#\n'
        printf '# artefact_sha256 is the build this box was walked with. A version does\n'
        printf '# NOT identify a build -- "1.0.50" named eleven distinct assemblies -- so\n'
        printf '# this is the field the publish gate binds on. artefact_sha256_source\n'
        printf '# reads measured(...) only when the DMG was found on the box and hashed\n'
        printf '# there; that establishes WHICH BUILD, not that it was the one mounted.\n'
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
        printf 'artefact_sha256\t%s\n'        "$ARTEFACT_SHA"
        printf 'artefact_sha256_source\t%s\n' "$ARTEFACT_SHA_SOURCE"
        printf 'walked_at\t%s\n'   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'box_fp\t%s\n'      "$BOX_FP"
        printf '#\n'
        printf '# instrument_rev answers the question this record has never\n'
        printf '# answered: WHICH PROBES graded that artefact. The subject is\n'
        printf '# named six ways above -- version, version_source,\n'
        printf '# artefact_sha256, artefact_sha256_source, box_fp, walked_at --\n'
        printf '# and the instrument was named nowhere.\n'
        printf '#\n'
        printf '# It matters because the probes do NOT come from the artefact. In\n'
        printf '# --from-dmg mode ttywalk.sh copies the .app Resources verbatim,\n'
        printf '# and gui/project.yml bundles box_walk_probes ZERO times, so the\n'
        printf '# suite that runs is the one in THIS checkout. A walk is therefore\n'
        printf '# artefact X judged by instrument Y, and only X was recorded.\n'
        printf '#\n'
        printf '# The case that forced it: no_person_holds_two_contact_cards\n'
        printf '# gained a collision-opportunity measure in #1549. Before it, a\n'
        printf '# clean graph printed a bare pass; after it, the same graph prints\n'
        printf '# EARNED or UNEXERCISED. BOTH WRITE THE SAME `pass` HERE. Reading\n'
        printf '# this file later, nobody could tell an earned zero from a vacuous\n'
        printf '# one -- which is the exact distinction that probe exists to make.\n'
        printf '#\n'
        printf '# instrument_source says HOW the value was obtained, same idiom as\n'
        printf '# version_source. A sha that does not describe the probes that ran\n'
        printf '# is worse than no sha, so local edits under box_walk_probes are\n'
        printf '# named rather than hidden behind a clean-looking commit id.\n'
        printf '#\n'
        printf '# 🔴 A CLEAN SHA DOES NOT MEAN main. It means the probes are EXACTLY\n'
        printf '# that commit, which may be a branch, a tag or a detached head. The\n'
        printf '# v1.0.71 walk ran from a harness branch that was main plus five\n'
        printf '# reset fixes: a correct, clean, committed sha that was nonetheless\n'
        printf '# not main. Resolve the sha before assuming the lineage -- this\n'
        printf '# field answers WHICH probes ran, never WHERE they came from.\n'
        printf 'instrument_rev\t%s\n'    "$INSTRUMENT_REV"
        printf 'instrument_source\t%s\n' "$INSTRUMENT_SOURCE"
        printf '#\n'
        printf '# stores_provenance answers the question every store-reading probe\n'
        printf '# begs and none of them state: was the graph this walk measured\n'
        printf '# CREATED by this artefact, or CARRIED OVER from a previous install?\n'
        printf '# A red from no_person_holds_two_contact_cards, people_stores_reconcile\n'
        printf '# or people_count_agreement means something different in each case. A\n'
        printf '# reset does NOT wipe: ttywalk.sh runs the shipped uninstaller if it can\n'
        printf '# find one and says so when it cannot.\n'
        printf 'stores_provenance\t%%s\n' "$STORES_PROVENANCE"
        printf 'counts_scope\tbox_walk_probes_only(phase1); verdict+qa_exit cover all phases\n'
        printf 'pass\t%s\n'        "${n_pass:-0}"
        printf 'fail\t%s\n'        "${n_fail:-0}"
        printf 'cannot_run\t%s\n'  "${n_cannot:-0}"
        printf 'broken\t%s\n'      "${n_broken:-0}"
        # COVERAGE, WHICH THE FOUR COUNTS ABOVE DO NOT CARRY.
        #
        # A BROKEN probe is counted in `broken` and then SKIPPED in phase 2 --
        # run_box_walk.sh:201-204 `case " $BROKEN_LIST " in ... continue`. It
        # therefore lands in exactly one bucket whether or not it measured
        # anything, so pass+fail+cannot_run+broken reaches the probe count
        # EITHER WAY.
        #
        # ⇒ that sum is a completeness check on ACCOUNTING and a bad one on
        # MEASUREMENT. On walks/v1.0.50.tsv it read 7+7+6+1 = 21 = the probe
        # count, as cleanly as if all 21 had run. Twenty had. The store-port
        # probe was broken, phase 2 stepped over it, and that walk took NO
        # store-port measurement at all -- on the STORE-EXPOSURE FINDING that
        # this probe exists to detect.
        #
        # DELIBERATELY NOT WRITTEN AS A BARE "#550". That integer means three
        # different things in three namespaces, and this file lives in the one
        # where GitHub turns it into a link:
        #     CM051 PR #550   "a kinship word is never a name"   <- what a
        #                      reader of this repo is sent to
        #     agent register  the store-exposure finding          <- what is meant
        # The probe's own header says "#550" five times and means the register.
        # Name the object, not the integer.
        #
        # The number that carries coverage is pass+fail+cannot_run, and it is
        # stated here rather than left to be derived, because a rising `broken`
        # silently converts measurements into non-measurements while the sum
        # stays perfect. Found by TNM 2026-08-30, sharpening my own reading of
        # the same reconciliation.
        _measured=$(( ${n_pass:-0} + ${n_fail:-0} + ${n_cannot:-0} ))
        if [ -n "$n_probes" ]; then
            # Reconcile IN THE FILE. If the buckets ever stop partitioning the
            # suite, the record says so instead of a reader assuming they did.
            if [ "$(( _measured + ${n_broken:-0} ))" -eq "$n_probes" ]; then
                _recon="buckets partition the suite"
            else
                _recon="DOES NOT RECONCILE -- $(( _measured + ${n_broken:-0} )) bucketed vs ${n_probes} probes"
            fi
            printf 'measured\t%s of %s (pass+fail+cannot_run; a broken probe is SKIPPED in phase 2 and measures nothing) -- %s\n' \
                   "$_measured" "$n_probes" "$_recon"
        else
            printf 'measured\t%s of UNKNOWN (probe total not parseable from the run log, so coverage cannot be stated -- this is not a claim that coverage was full)\n' \
                   "$_measured"
        fi
        printf 'verdict\t%s\n'     "$VERDICT"
        printf 'qa_exit\t%s\n'     "$overall"
        # RECONCILE THE NAMES AGAINST THE COUNT, IN THE FILE.
        # If the parser above ever stops matching -- a header reworded, an
        # indent changed -- it returns nothing and the record would quietly go
        # back to counts with no names, which is the exact blindness being
        # fixed and would look like a clean walk with nothing to report. This
        # line makes that visible to anyone reading the record.
        printf 'failed_probe_names_recorded\t%s of %s\n' "${n_failed_named:-0}" "${n_fail:-0}"
        printf '%s\n' "$FAILED_NAMES"  | while IFS= read -r _n; do [ -n "$_n" ] && printf 'failed_probe\t%s\n' "$_n"; done
        # 🔴 AND THE SAME COURTESY FOR THE FAILURES, WHICH NEVER GOT IT.
        #
        # MEASURED on walks/v1.0.68.tsv: the record carries
        # `not_measured_reasons` telling a reader where the CANNOT-RUN
        # explanations live, and for the five `failed_probe` rows it carries
        # nothing at all. So the record explains why it could not LOOK, and
        # says nothing about what it SAW -- and a FAIL is the more serious of
        # the two states.
        #
        # run_box_walk.sh has captured these since #1348: it builds FAIL_REASONS
        # and prints them under "WHAT EACH FAILURE FOUND". A reader of the
        # record has no way to know that block exists, and would reasonably
        # infer the reasons were never captured. That is the same wrong
        # inference the not_measured_reasons row was added to prevent.
        #
        # WITHHELD FOR THE SAME REASON, NOT A DIFFERENT ONE: probe_fail details
        # interpolate ${OSTLER_BOX_HOST}, store URLs, ~/.ostler/... paths and
        # record counts, and walks/ is a PUBLIC repo. This row is a pointer,
        # never the prose.
        if [ -n "$FAILED_NAMES" ]; then
            printf 'failed_probe_reasons\twithheld(public repo); run_box_walk.sh prints them under "WHAT EACH FAILURE FOUND"\n'
        fi
        # THE REASONS ARE WITHHELD, AND THE RECORD SAYS SO RATHER THAN LEAVING
        # A READER TO CONCLUDE NONE EXIST.
        #
        # run_box_walk.sh now prints the missing prerequisite for every
        # CANNOT-RUN, because lib/probe.sh requires probe_cannot_run() to name
        # it. Those strings are NOT published here: measured across the 90
        # probe_cannot_run call sites in 21 of 21 probes, they interpolate
        # ${OSTLER_BOX_HOST}, $LOG_PATH, ~/.ostler/... and in one case raw ssh
        # stderr. walks/ is committed to a PUBLIC repo, which is the same
        # reason box_fp is a hash and the reason section_names() above accepts
        # bare probe names and nothing else.
        #
        # Redacting 90 free-prose sites would fail open on the first one that
        # gained a new path, so the reasons stay on the console and this row
        # says where to look. A reader who sees not_measured_probe rows and no
        # explanation would otherwise reasonably infer the reason was never
        # captured -- which was true until 2026-08-30 and is now not.
        if [ -n "$NOTMEAS_NAMES" ]; then
            printf 'not_measured_reasons\twithheld(public repo); run_box_walk.sh prints them under "PREREQUISITES THAT WERE ABSENT"\n'
        fi
        printf '%s\n' "$NOTMEAS_NAMES" | while IFS= read -r _n; do [ -n "$_n" ] && printf 'not_measured_probe\t%s\n' "$_n"; done
        printf '%s\n' "$BROKEN_NAMES"  | while IFS= read -r _n; do [ -n "$_n" ] && printf 'broken_probe\t%s\n' "$_n"; done
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
