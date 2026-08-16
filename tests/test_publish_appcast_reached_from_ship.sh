#!/usr/bin/env bash
#
# test_publish_appcast_reached_from_ship.sh -- CONTROL B.
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

# --- 1. REACHABLE ---------------------------------------------------------
if grep -qxF "$WANTED" "$WORK/seen"; then
    # Walk the parents back so the reader gets the route, not just a verdict.
    path="$WANTED"; cur="$WANTED"
    while :; do
        up="$(grep -m1 -F "$(printf '%s\t' "$cur")" "$WORK/parent" | cut -f2)"
        [ -z "$up" ] || [ "$up" = "-" ] && break
        path="$up -> $path"; cur="$up"
    done
    echo "  [OK] REACHABLE: $path"
else
    FAIL=1
    echo >&2
    echo "  [FAIL] '$WANTED' is NOT reachable from '$ROOT_TARGET'." >&2
    if grep -qE "^${WANTED}:" "$GRAPH"; then
        line="$(grep -nE "^${WANTED}:" "$MAKEFILE" | head -1 | cut -d: -f1)"
        echo >&2
        echo "  IT IS DEFINED. gui/Makefile line ${line:-?} declares it, and the cut" >&2
        echo "  cannot get to it. That is not a near miss, it is the ORIGINAL defect" >&2
        echo "  reproduced one layer up: CM050's publisher was also written, merged" >&2
        echo "  and called by nothing, and every Hub silently stopped receiving" >&2
        echo "  updates. Every grep for the name still hits. Add it to the 'ship:'" >&2
        echo "  prerequisite list, LAST, after archive." >&2
    else
        echo "  It is not defined anywhere either. Define the target AND name it in" >&2
        echo "  the 'ship:' prerequisite list -- doing only the first is the defect." >&2
    fi
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

# --- 3. ORDERED -----------------------------------------------------------
SHIP_LINE="$(grep -m1 "^${ROOT_TARGET}:" "$GRAPH")"
ORDERED="$WORK/ordered.txt"
printf '%s\n' "${SHIP_LINE#*:}" | tr ' ' '\n' | grep . >"$ORDERED"
pos_of() { grep -nxF "$1" "$ORDERED" | head -1 | cut -d: -f1; }

want_pos="$(pos_of "$WANTED")"
if [ -z "$want_pos" ]; then
    echo "  [skip] ORDERING not checked: '$WANTED' is not a DIRECT prerequisite of" \
         "'$ROOT_TARGET' (see the reachability result above)."
else
    bad=""
    for gate in "${MUST_PRECEDE[@]}"; do
        gpos="$(pos_of "$gate")"
        if [ -z "$gpos" ]; then
            # Its absence is Control A's finding, not this one's. Say so rather
            # than silently treating a missing gate as a satisfied ordering.
            bad="$bad\n    ? $gate is not in 'ship:' at all (see test_ship_prereqs_are_a_superset.sh)"
        elif [ "$gpos" -gt "$want_pos" ]; then
            bad="$bad\n    - $gate is at position $gpos, AFTER $WANTED at position $want_pos"
        fi
    done
    if [ -z "$bad" ]; then
        echo "  [OK] ORDERED: '$WANTED' is at position $want_pos of $(grep -c . "$ORDERED"), after every verification gate."
    else
        FAIL=1
        echo >&2
        echo "  [FAIL] '$WANTED' is sequenced wrongly in the 'ship:' prerequisite list:" >&2
        printf "%b\n" "$bad" >&2
        echo >&2
        echo "  GNU make builds prerequisites left to right, so serially that list is" >&2
        echo "  the running order. Publishing before a gate means a release that FAILED" >&2
        echo "  verification can still be advertised to every installed Hub -- and a" >&2
        echo "  published appcast row cannot be recalled from a machine that fetched it." >&2
        echo "  Move '$WANTED' to the END of the list." >&2
    fi
fi

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
echo "  all three assertions hold."
exit 0
