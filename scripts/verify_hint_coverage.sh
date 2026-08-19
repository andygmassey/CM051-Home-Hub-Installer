#!/usr/bin/env bash
# Every step install.sh announces to the customer must have hint copy, and
# every entry in the hint copy must correspond to a step that is really
# announced.
#
# WHY THIS EXISTS
#   install.sh emitted 39 distinct step ids. HintCopy.json covered 27, and 4
#   of those 27 were for steps that no longer exist. So 16 of 39 steps -- 41%
#   of the install -- rendered with no subtitle and no explanation of what was
#   happening or why. `hydrate_graph` was one of them, and it is the step Andy
#   screenshotted on the v1.0.33 walk.
#
#   Nothing caught this because nothing compared the two lists. The emitter is
#   a shell script and the copy is a JSON file; they drift by default and only
#   a customer looking at the screen finds out.
#
# CONTRACT
#   rc=0  every emitted step id has copy, and no entry is an orphan
#   rc=1  a step would render with no copy, or an entry is dead
#   rc=2  a file this gate must read is absent or unparseable
#
# Controls: scripts/tests/test_hint_coverage.sh
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SH="$ROOT/install.sh"
HINT="$ROOT/gui/OstlerInstaller/Resources/HintCopy.json"

for f in "$SH" "$HINT"; do
    if [ ! -f "$f" ]; then
        printf 'CANNOT RUN  missing %s -- this gate cannot compare two lists when one is absent\n' "$f"
        exit 2
    fi
done

# Step ids the customer is actually shown, taken from the emitter itself:
#   progress "<title>" "<step_id>"
# Parsing the emitter rather than a hand-kept list is the whole point. A list
# someone remembers to update is the mechanism that already failed.
emitted="$(grep -oE '^[[:space:]]*progress[[:space:]]+"[^"]*"[[:space:]]+"[a-z0-9_]+"' "$SH" \
    | grep -oE '"[a-z0-9_]+"[[:space:]]*$' | tr -d '"' | sort -u)"

if [ -z "$emitted" ]; then
    printf 'CANNOT RUN  found no `progress "..." "<id>"` calls in install.sh at all.\n'
    printf '            A zero here means the pattern stopped matching, not that the\n'
    printf '            installer stopped having steps. Refusing to report coverage.\n'
    exit 2
fi

covered="$(python3 -c '
import io, json, sys
try:
    d = json.load(io.open(sys.argv[1], encoding="utf-8"))
except Exception as e:
    sys.stderr.write("unparseable: %s\n" % e)
    raise SystemExit(9)
print("\n".join(sorted(d.keys())))
' "$HINT")" || { printf 'CANNOT RUN  %s does not parse as JSON -- every hint panel would be blank\n' "$HINT"; exit 2; }

emitted_n="$(printf '%s\n' "$emitted" | grep -c .)"
covered_n="$(printf '%s\n' "$covered" | grep -c .)"

missing="$(comm -23 <(printf '%s\n' "$emitted") <(printf '%s\n' "$covered"))"
orphan="$(comm -13 <(printf '%s\n' "$emitted") <(printf '%s\n' "$covered"))"

# Steps that exist but predate the emitter contract, or are announced by a
# path this gate does not parse. Each needs a reason, not just a name.
ORPHAN_ALLOWED="health_check prereq_check setup_complete_wrap_up setup_questions"

rc=0

if [ -n "$missing" ]; then
    printf 'FAIL  %d of %d steps install.sh announces have NO hint copy.\n' \
        "$(printf '%s\n' "$missing" | grep -c .)" "$emitted_n"
    printf '      Each renders with a synthesised title, no subtitle and no "why":\n'
    printf '%s\n' "$missing" | sed 's/^/        /'
    rc=1
fi

for o in $orphan; do
    case " $ORPHAN_ALLOWED " in
        *" $o "*) continue ;;
    esac
    printf 'FAIL  HintCopy.json carries "%s", which install.sh never announces.\n' "$o"
    printf '      Dead copy is not harmless: it is the thing people read instead of\n'
    printf '      checking, and it hid the real gap for four releases.\n'
    rc=1
done

if [ $rc -eq 0 ]; then
    printf 'verify_hint_coverage: OK -- %d emitted steps, %d entries, every step covered\n' \
        "$emitted_n" "$covered_n"
fi
exit $rc
