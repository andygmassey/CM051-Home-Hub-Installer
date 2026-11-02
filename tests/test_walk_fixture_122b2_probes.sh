#!/usr/bin/env bash
# meetings_index_lists_meetings_not_holidays and birthday_listed_once_per_person: the judges
# (scripts/box_walk_probes/lib/walk_fixture_122b2.py) on synthetic input, each probe's own
# --self-test (negative control), and the CANNOT-RUN path when the box has no pipeline venv.
# Mutant: WF_MUTANT=1 makes judge_birthday accept any served count >= 1 (the dedupe-bypassed
# shape), which must turn this test RED.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
P=scripts/box_walk_probes/probes
L="${WF_LIB_UNDER_TEST:-scripts/box_walk_probes/lib/walk_fixture_122b2.py}"
fails=0; total=0
ok()  { total=$((total + 1)); echo "  ok    $1"; }
bad() { total=$((total + 1)); fails=$((fails + 1)); echo "  FAIL  $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if [ "${WF_MUTANT:-0}" = "1" ]; then
    sed 's/if served_rows == 1:/if served_rows >= 1:/' "$L" > "$TMP/walk_fixture_122b2.py"; L="$TMP/walk_fixture_122b2.py"
fi
py() { /usr/bin/python3 -I -c 'import sys, importlib.util
spec = importlib.util.spec_from_file_location("wf", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
exec(sys.argv[2])' "$L" "$1"; }
want() { # label, python expr printing a value, expected
    local got; got="$(py "$2" 2>&1)"
    if [ "$got" = "$3" ]; then ok "$1 -> $3"; else bad "$1: wanted '$3', got '$got'"; fi
}
IDX='"---\ntitle: Meetings\n---\n\n- [Walkfixture Planning Review](a.md)\n"'
want "meeting present, holiday absent"      "print(m.judge_meetings($IDX)[0])" ok
want "holiday listed"                       "print(m.judge_meetings($IDX + '- Walkfixture Bank Holiday\n')[0])" FAIL
want "control: expects holiday, absent"     "print(m.judge_meetings($IDX, expect_holiday=True)[0])" FAIL
want "meeting missing"                      "print(m.judge_meetings('---\ntitle: Meetings\n---\n')[0])" FAIL
want "empty index is CANNOT, not absent"    "print(m.judge_meetings('')[0])" CANNOT
want "not the Meetings index"               "print(m.judge_meetings('# People')[0])" CANNOT
want "birthday once over 4 raw rows"        "print(m.judge_birthday(1, 4)[0])" ok
want "birthday twice over 4 raw rows"       "print(m.judge_birthday(2, 4)[0])" FAIL
want "vacuous one over 1 raw row"           "print(m.judge_birthday(1, 1)[0])" CANNOT
want "birthday never served"                "print(m.judge_birthday(0, 4)[0])" FAIL
want "unreadable served count"              "print(m.judge_birthday(None, 4)[0])" CANNOT
want "brief names once"                     "print(m.judge_brief_birthday('Birthdays: Ann Quillfeather today')[0])" ok
want "brief names twice"                    "print(m.judge_brief_birthday('Birthdays: Ann Quillfeather and Bo Quillfeather today')[0])" FAIL
want "brief omits the birthday"             "print(m.judge_brief_birthday('Nothing today')[0])" CANNOT
want "name outside the birthday lines ignored" "print(m.judge_brief_birthday('Quillfeather called\nBirthdays: Ann Quillfeather today')[0])" ok
want "seed SPARQL carries the surname twice" "print(m.bday_seed_update().count('Quillfeather'))" 3
want "delete is scoped to the fixture IRI"  "print('STRSTARTS' in m.delete_update() and 'example.com/walkfixture122b2/' in m.delete_update())" True

for p in meetings_index_lists_meetings_not_holidays birthday_listed_once_per_person; do
    out="$(bash "$P/$p.sh" --self-test 2>&1)"
    case "$out" in *"VERDICT: FAIL -- negative control behaved correctly"*) ok "$p --self-test: control fires" ;; *) bad "$p --self-test: $out" ;; esac
    h="$TMP/home-$p"; mkdir -p "$h"
    out="$(env -u OSTLER_BOX_HOST HOME="$h" bash "$P/$p.sh" 2>&1)"; rc=$?
    case "$out" in *"VERDICT: CANNOT-RUN"*) [ "$rc" = 78 ] && ok "$p: no pipeline venv -> CANNOT-RUN (rc 78)" || bad "$p: rc $rc" ;; *) bad "$p: wanted CANNOT-RUN, got: $out" ;; esac
done
echo "$((total - fails))/$total passed"
[ "$fails" -eq 0 ]
