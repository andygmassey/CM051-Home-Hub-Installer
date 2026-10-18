#!/usr/bin/env bash
# A PROBE THAT WRITES DECLARES IT, AND A DECLARED WRITER IS NEVER PROMOTED.
#
# The full walk moves the previous walk's FAILed probes to the front
# (lib/promote_order.sh). Moving a probe that CHANGES the box changes what every
# later probe reads, so a verdict moves through ordering alone. Concretely
# people_stores_reconcile kickstarts the people writers; promoted, it starts a
# sync before hub_screens_*, no_person_holds_two_contact_cards and
# assistant_answers_grounded read people.
#
# The decision reads a marker, never a grep: `# WALK_WRITES: <what>`. Because a
# marker can be forgotten, a LINT fails any probe whose executable lines (comment
# lines stripped) contain a writing shape and that has neither the marker nor a
# reviewed `# WALK_READ_ONLY: <why>` acknowledgement.
#
# Writes the lint cannot see through a plain shell word (a lib call that creates
# a todo / reminder) are listed in SHAPES by the call's name.
#
# Each absence is paired with a control: the lint must flag an unmarked fixture
# for EACH shape, and pass the same fixture once marked.
#
# EXIT 0 pass, 1 fail, 2 cannot-run. BASH 3.2.
set -uo pipefail
REPO_UNDER="${REPO_UNDER_TEST:-$(cd "$(dirname "$0")/.." && pwd)}"
DIR="${REPO_UNDER}/scripts/box_walk_probes/probes"
LIB="${REPO_UNDER}/scripts/box_walk_probes/lib/promote_order.sh"
[ -d "$DIR" ] || { echo "CANNOT-RUN: no probe dir $DIR" >&2; exit 2; }
[ -f "$LIB" ] || { echo "CANNOT-RUN: no $LIB" >&2; exit 2; }
PASS=0; FAIL=0
ok()  { printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  [FAIL] %s\n' "$1"; FAIL=$((FAIL+1)); }

# The writing shapes, matched on non-comment lines only.
SHAPES='launchctl[[:space:]]+(kickstart|bootstrap|bootout|load|unload)|"kickstart"|-X[[:space:]]+(POST|PUT|PATCH|DELETE)|INSERT[[:space:]]+(DATA|INTO)|DELETE[[:space:]]+(WHERE|DATA|FROM)|companion_pair_box_snippet|todo_reminders_box\.py|src\.conversation_writer|src\.reminders_push'

# lint_file <file> -> 0 clean, 1 unmarked writer
lint_file() {
    local f="$1" hits
    hits="$(grep -v -E '^[[:space:]]*#' "$f" | grep -c -E "$SHAPES")"
    [ "$hits" -eq 0 ] && return 0
    [ "$(grep -c -E '^# (WALK_WRITES|WALK_READ_ONLY):' "$f")" -gt 0 ] && return 0
    return 1
}

echo "--- lint: every real probe is clean or marked ---"
n=0; unmarked=""
for f in "$DIR"/*.sh; do
    n=$((n+1)); lint_file "$f" || unmarked="$unmarked $(basename "$f" .sh)"
done
[ -z "$unmarked" ] && ok "all ${n} probes: no unmarked writing shape" || bad "unmarked writing probe(s):${unmarked}"

echo "--- lint control: it flags an unmarked fixture, per shape, and passes it once marked ---"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
i=0
for shape in 'launchctl kickstart gui/501/x' 'curl -X POST http://h/p' 'INSERT DATA { }' 'DELETE WHERE { ?s ?p ?o }' 'companion_pair_box_snippet' 'python3 lib/todo_reminders_box.py run' 'from src.conversation_writer import write'; do
    i=$((i+1)); f="$W/fx$i.sh"
    printf '#!/usr/bin/env bash\n# a comment mentioning launchctl kickstart is not a hit\nrun %s\n' "$shape" > "$f"
    if lint_file "$f"; then bad "lint MISSED an unmarked fixture: ${shape}"; else
        printf '# WALK_WRITES: fixture\n' >> "$f"
        lint_file "$f" && ok "flagged unmarked, passes marked: ${shape}" || bad "marked fixture still flagged: ${shape}"
    fi
done
printf '#!/usr/bin/env bash\n# launchctl kickstart in a comment only\necho hi\n' > "$W/c.sh"
lint_file "$W/c.sh" && ok "a writing shape inside a comment alone is not a hit" || bad "comment-only mention was flagged"

echo "--- the known writers are marked ---"
for w in pairing_recovers_without_a_repair_storm people_stores_reconcile pair_endpoints_refuse_off_window todos_reach_reminders; do
    [ "$(grep -c '^# WALK_WRITES:' "$DIR/$w.sh")" -gt 0 ] && ok "$w declares WALK_WRITES" || bad "$w is not marked WALK_WRITES"
done

echo "--- a declared writer keeps its place when promoted ---"
# shellcheck disable=SC1090
. "$LIB"
PROBES="$(for f in "$DIR"/*.sh; do printf '%s\n' "$f"; done | LC_ALL=C sort | tr '\n' ' ')"
names_of() { for p in $1; do basename "$p" .sh; done; }
BASE="$(names_of "$PROBES")"
rest_of() { printf '%s\n' "$1" | grep -v -x -E "$2"; }
for w in people_stores_reconcile pairing_recovers_without_a_repair_storm pair_endpoints_refuse_off_window todos_reach_reminders; do
    ORD="$(names_of "$(promote_order "$w")")"
    [ "$ORD" = "$BASE" ] && ok "promoting only ${w}: order identical to C-sorted (not moved)" || bad "${w} was moved"
done
ORD="$(names_of "$(promote_order "people_stores_reconcile
ingest_coverage
pairing_recovers_without_a_repair_storm")")"
[ "$(printf '%s\n' "$ORD" | head -1)" = "ingest_coverage" ] && ok "a read-only probe in the same list IS promoted (control: promotion works)" || bad "ingest_coverage not promoted, so the not-moved results above prove nothing"
WANT="$(printf '%s\n' "$BASE" | grep -v -x ingest_coverage)"
[ "$(printf '%s\n' "$ORD" | grep -v -x ingest_coverage)" = "$WANT" ] \
    && ok "everything not promoted, writers included, keeps its relative C-sorted order" || bad "non-promoted order changed"
[ "$(promote_writers_named "people_stores_reconcile ingest_coverage")" = "people_stores_reconcile" ] \
    && ok "promote_writers_named reports exactly the writer (for the PROMOTION: not moved line)" || bad "promote_writers_named wrong"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
