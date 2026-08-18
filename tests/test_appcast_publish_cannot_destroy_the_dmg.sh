#!/usr/bin/env bash
#
# test_appcast_publish_cannot_destroy_the_dmg.sh -- CONTROL B.
#
# `publish-appcast` must be REACHED FROM `ship:`, not merely defined.
#
# Exit 0  the cut reaches it, it has a recipe, and it runs after the gates.
# Exit 1  it is unreachable, bodiless, or sequenced before a gate it must
#         never precede. The reason is named.
# Exit 2  CANNOT RUN. Nothing has been found wrong; this failed to LOOK.
#
# ============================================================================
# WHY "DEFINED" IS THE WRONG QUESTION
# ============================================================================
#
# A defined-but-unreachable target is PRECISELY the defect this change exists
# to fix. CM050's publisher was written, tested and merged, and then nothing
# ever called it: three pieces of auto-update existed and only two were
# connected, so every installed Hub polled a feed that would never list a
# newer release and stayed on its version for ever, silently.
#
# Re-creating that shape one layer up is the obvious way to get this wrong.
# `publish-appcast:` sitting in gui/Makefile, reached by nothing, would satisfy
# every naive check available:
#
#     grep -R 'publish-appcast' gui/Makefile        -> hits
#     grep -c 'publish-appcast' gui/Makefile        -> non-zero
#     make publish-appcast                          -> works, by hand
#
# and the cut would still never run it. So this control asks the only question
# that distinguishes the two states: starting at `ship`, and following
# prerequisites, can make GET THERE.
#
# THREE ASSERTIONS, because reachability alone is not sufficient:
#
#   1. REACHABLE.  A prerequisite path exists from ship to publish-appcast.
#   2. HAS A BODY. It is a real target with a recipe, not a name make would
#      resolve to a missing file. Reachable-but-bodiless is the mirror defect
#      and fails a cut at its very last step, after notarisation has been paid
#      for.
#   3. ORDERED.    Within ship's own prerequisite list it comes AFTER
#      verify-dmg-contents, verify-stapling, verify-commit-parity and archive.
#      GNU make builds prerequisites left to right, so serially that list IS
#      the running order. Publishing a feed entry for an artefact that failed
#      verification is worse than not publishing: a failed DMG stays on the
#      shelf, but a published appcast row goes out to every installed machine
#      and cannot be recalled from the ones that already fetched it.
#
# Assertion 3 is deliberately a list-position check and NOT the whole story.
# `make -j` gives no ordering promise at all, which is why publish-appcast also
# re-derives its evidence at run time (DMG present, Hub bundle stapled). Two
# mechanisms, because this one is a property of the file and that one is a
# property of the run, and neither implies the other.
#
# ============================================================================
# THE GRAPH COMES FROM MAKE, NOT FROM A REGEX
# ============================================================================
#
# `make -p` prints make's own database, including a `# Files` section listing
# every target with its prerequisites AFTER variable expansion. Make decides
# what depends on what, so make is asked. A hand-rolled parser would hold an
# opinion about variables, line continuations and included files, and the first
# time it disagreed with make it would be wrong and confident.
#
# `-p -n <a target that does not exist>` prints the database and stops: make
# rejects the unknown goal before considering any rule, so no recipe is
# reached. That matters beyond tidiness -- gui/Makefile has a recipe containing
# $(MAKE), and $(MAKE) lines DO execute under -n.
#
# British English throughout; " -- " not em-dashes.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAKEFILE="$REPO_ROOT/gui/Makefile"
ROOT_TARGET="ship"
WANTED="publish-appcast"

# Gates that must have run before anything is advertised to customers.
MUST_PRECEDE=(verify-dmg-contents verify-stapling verify-commit-parity archive)

while [ $# -gt 0 ]; do
    case "$1" in
        # Point the test at a COPY. This is how the control is proven RED:
        # detach the target on a copy and watch this fail. Mutating the tracked
        # file to prove a test works risks leaving the mutation behind.
        --makefile) MAKEFILE="${2:-}"; shift 2 ;;
        -h|--help)  echo "usage: $0 [--makefile <path to a gui/Makefile>]"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ ! -f "$MAKEFILE" ]; then
    echo "appcast-reachability: CANNOT RUN -- no Makefile at $MAKEFILE" >&2
    exit 2
fi
if ! command -v make >/dev/null 2>&1; then
    echo "appcast-reachability: CANNOT RUN -- make is not on PATH." >&2
    exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/appcastreach-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

cp "$MAKEFILE" "$WORK/Makefile"
DUMP="$WORK/dump.txt"
( cd "$WORK" && make -p -n __appcast_reach_probe_no_such_target__ ) >"$DUMP" 2>"$WORK/err.txt"

if ! grep -q '^# Files' "$DUMP"; then
    echo "appcast-reachability: CANNOT RUN -- make printed no '# Files' section." >&2
    echo "  The Makefile probably failed to parse, so the graph was never read." >&2
    echo "  This has NOT found the target unreachable. make said:" >&2
    sed 's/^/    /' "$WORK/err.txt" >&2
    exit 2
fi

# --- the graph ------------------------------------------------------------
# Every line in the # Files section of the form  target: prereqs.  Built-in
# suffix rules (.c.o: and friends) come along too; they are unreachable from
# ship and cost nothing.
GRAPH="$WORK/graph.txt"
awk '/^# Files$/{f=1; next} /^# files hash-table stats/{f=0} f' "$DUMP" \
  | grep -E '^[^ 	#][^:=]*:([^=]|$)' >"$GRAPH" || true

if [ ! -s "$GRAPH" ]; then
    echo "appcast-reachability: CANNOT RUN -- 0 rules parsed out of make's database." >&2
    echo "  A zero here is a broken reader, not an empty graph: this Makefile has" >&2
    echo "  dozens of targets. Refusing to report a verdict." >&2
    exit 2
fi

prereqs_of() {  # $1 = target -> prerequisites, one per line
    grep -E "^$(printf '%s' "$1" | sed 's/[][\.*^$/]/\\&/g'):" "$GRAPH" \
      | sed 's/^[^:]*://' | tr ' ' '\n' | grep . | sort -u
}

# THE PROBE MUST BE VALIDATED BEFORE ITS ANSWER IS BELIEVED. If `ship` is not
# in the graph, "publish-appcast is unreachable" would be true and completely
# misleading: nothing is reachable from a root that does not exist.
if ! grep -qE "^${ROOT_TARGET}:" "$GRAPH"; then
    echo "appcast-reachability: CANNOT RUN -- no '${ROOT_TARGET}:' rule in make's database." >&2
    echo "  Nothing is reachable from a root that is not there, so every target" >&2
    echo "  would report unreachable and the run would read as a catastrophe" >&2
    echo "  rather than as a broken probe." >&2
    exit 2
fi

# --- fixpoint: breadth-first from ship, keeping the path ------------------
: >"$WORK/seen"
printf '%s\n' "$ROOT_TARGET" >"$WORK/seen"
printf '%s\n' "$ROOT_TARGET" >"$WORK/frontier"
printf '%s\t-\n' "$ROOT_TARGET" >"$WORK/parent"
hops=0
while [ -s "$WORK/frontier" ]; do
    hops=$((hops + 1))
    : >"$WORK/next"
    while IFS= read -r node; do
        while IFS= read -r p; do
            grep -qxF "$p" "$WORK/seen" && continue
            printf '%s\n' "$p" >>"$WORK/seen"
            printf '%s\t%s\n' "$p" "$node" >>"$WORK/parent"
            printf '%s\n' "$p" >>"$WORK/next"
        done < <(prereqs_of "$node")
    done <"$WORK/frontier"
    mv "$WORK/next" "$WORK/frontier"
done

reached_total="$(grep -c . "$WORK/seen" | tr -d ' ')"
echo "appcast-reachability: ${reached_total} target(s) reachable from '${ROOT_TARGET}' (fixpoint in ${hops} round(s))."

FAIL=0

# --- 1. NOT REACHABLE FROM ship: ------------------------------------------
# THIS ASSERTION IS INVERTED FROM ITS ORIGINAL FORM, AND v1.0.34 IS THE REASON.
#
# It used to require that publish-appcast BE reachable from ship:, last, after
# archive. That is what #776 wired, and it worked -- it fired on the very first
# cut that reached it, and firing there destroyed the build.
#
# MEASURED, run 32093975602, tag v1.0.34:
#   03:10:03  DMG notarised, status: Accepted
#   03:10:03  stapled, "The staple and validate action worked!"
#   03:10:04  spctl, source=Notarized Developer ID
#   03:10:09  publish-appcast: OSTLER_SPARKLE_SIGNING_KEY unset -> Error 1
#   make ship non-zero -> "Verify the artefact" SKIPPED, upload SKIPPED
#   actions/runs/32093975602/artifacts -> total_count = 0
#
# A finished, notarised, stapled, parity-verified DMG existed for five seconds
# on an ephemeral runner and no human ever had it. The version number is spent.
#
# So the rule is now the opposite: NOTHING THAT CAN FAIL MAY SIT BETWEEN A
# VERIFIED ARTEFACT AND ITS UPLOAD. Publishing an appcast advertises a build to
# customers; doing it before the build is retrievable is backwards anyway.
if grep -qxF "$WANTED" "$WORK/seen"; then
    FAIL=1
    path="$WANTED"; cur="$WANTED"
    while :; do
        up="$(grep -m1 -F "$(printf '%s\t' "$cur")" "$WORK/parent" | cut -f2)"
        [ -z "$up" ] || [ "$up" = "-" ] && break
        path="$up -> $path"; cur="$up"
    done
    echo >&2
    echo "  [FAIL] '$WANTED' IS reachable from '$ROOT_TARGET': $path" >&2
    echo >&2
    echo "  Anything in the 'ship:' graph can fail, and a failure anywhere in it" >&2
    echo "  aborts the run before the artefact is uploaded. On v1.0.34 that cost a" >&2
    echo "  fully notarised DMG and a version number (run 32093975602, artifacts" >&2
    echo "  total_count=0). Take it back out of 'ship:' and invoke it from the cut" >&2
    echo "  workflow AFTER the upload step -- assertion 3 checks that half." >&2
else
    echo "  [OK] NOT REACHABLE from '$ROOT_TARGET': it cannot abort the cut before upload."
fi

# --- 2. HAS A BODY --------------------------------------------------------
# make 3.81 prints "commands to execute", make 4.x prints "recipe to execute".
# The cut host is macOS (3.81); CI is ubuntu (4.x). Match both, or this
# assertion passes on one platform and cannot run on the other.
body="$(awk -v t="^${WANTED}:" '
    $0 ~ t {inblock=1; next}
    inblock && /^[^ \t#]/ {inblock=0}
    inblock && (/commands to execute/ || /recipe to execute/) {print "yes"; exit}
' "$DUMP")"
if [ "$body" = "yes" ]; then
    echo "  [OK] HAS A BODY: '$WANTED' is a real target with a recipe."
else
    FAIL=1
    echo >&2
    echo "  [FAIL] '$WANTED' has no recipe -- make would treat it as a missing file." >&2
    echo "  A reachable name with nothing behind it fails the cut at its LAST step," >&2
    echo "  after the notarisation cycles have already been spent." >&2
fi

# --- 3. STILL INVOKED BY THE CUT, AND ONLY AFTER THE UPLOAD ----------------
# Removing it from ship: must NOT re-dark it. #370 was "auto-update is dark
# because nothing calls the publisher", and #776 is the fix; deleting the call
# site instead of moving it would reinstate the original defect and this file
# would have helped. So the enforcement moves with the call: the cut workflow
# must invoke publish-appcast, and it must do so AFTER the upload step.
WF="${OSTLER_CUT_WORKFLOW:-$REPO_ROOT/.github/workflows/cut.yml}"
if [ ! -f "$WF" ]; then
    echo "appcast-ordering: CANNOT RUN -- no workflow at $WF" >&2
    exit 2
fi
up_line="$(grep -n 'uses: actions/upload-artifact' "$WF" | head -1 | cut -d: -f1)"
pub_line="$(grep -n 'make -C gui publish-appcast' "$WF" | head -1 | cut -d: -f1)"
if [ -z "$up_line" ]; then
    echo "appcast-ordering: CANNOT RUN -- no upload-artifact step found in cut.yml." >&2
    echo "  Nothing was compared. This has NOT found the ordering correct." >&2
    exit 2
fi
if [ -z "$pub_line" ]; then
    FAIL=1
    echo >&2
    echo "  [FAIL] cut.yml never invokes 'make -C gui publish-appcast'." >&2
    echo "  It was taken out of 'ship:' and not re-attached anywhere, so the" >&2
    echo "  publisher is called by nothing. That is task #370 exactly: CM050's" >&2
    echo "  publisher written, merged, and dark, with every Hub silently not" >&2
    echo "  receiving updates. Removing the hazard must not remove the feature." >&2
elif [ "$pub_line" -lt "$up_line" ]; then
    FAIL=1
    echo >&2
    echo "  [FAIL] publish-appcast (line $pub_line) runs BEFORE the upload (line $up_line)." >&2
    echo "  That is the v1.0.34 shape again: a step that can fail, sitting between" >&2
    echo "  a verified artefact and the only action that makes it retrievable." >&2
else
    echo "  [OK] INVOKED AFTER UPLOAD: cut.yml publishes at line $pub_line, upload at line $up_line."
fi

# --- 4. THE ARTEFACT IS CAPTURED UNCONDITIONALLY ---------------------------
# The class this file now guards is bigger than publish-appcast, and it has
# fired three times: v1.0.26 (a bad find path), v1.0.34 (the Sparkle key), and
# it would fire again for any future step that can go red while holding a good
# DMG. The trigger changed each time. The shape did not: the staging step and
# the upload had no `if:`, so GitHub's default -- run only if everything before
# succeeded -- discarded a notarised build with the runner.
#
# Capturing the artefact and blessing it are different questions. These two
# steps answer the first one and must not be gated on the second.
py_ok=1
command -v python3 >/dev/null 2>&1 || py_ok=0
if [ "$py_ok" -eq 0 ]; then
    echo "  [skip] CAPTURE-UNCONDITIONAL not checked: python3 unavailable to parse YAML."
else
    cap="$(python3 - "$WF" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d['jobs']['cut']['steps']
bad = []
for s in steps:
    n = str(s.get('name') or s.get('uses') or '')
    if 'Verify the artefact' in n or 'upload-artifact' in n:
        if str(s.get('if', '')).strip() != 'always()':
            bad.append('%s (if=%s)' % (n[:52], s.get('if', '<none>')))
print('|'.join(bad))
PYEOF
)" || cap="CANNOT"
    if [ "$cap" = "CANNOT" ]; then
        echo "  [skip] CAPTURE-UNCONDITIONAL not checked: could not parse the workflow."
    elif [ -z "$cap" ]; then
        echo "  [OK] CAPTURED UNCONDITIONALLY: staging and upload both carry if: always()."
    else
        FAIL=1
        echo >&2
        echo "  [FAIL] a DMG-capture step is conditional on everything before it succeeding:" >&2
        printf '    %s\n' "$cap" | tr '|' '\n' >&2
        echo >&2
        echo "  With no 'if: always()', GitHub runs these only when every prior step" >&2
        echo "  passed -- so one unrelated red discards a notarised, stapled DMG with" >&2
        echo "  the ephemeral runner. That is v1.0.26 and v1.0.34, twice, same shape," >&2
        echo "  different triggers. Both steps need it: staging happens INSIDE the" >&2
        echo "  verify step, so guarding one without the other captures nothing." >&2
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "  all four assertions hold: not in ship, has a body, invoked after upload, artefact captured unconditionally."
exit 0
