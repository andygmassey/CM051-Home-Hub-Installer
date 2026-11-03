# walk_fixture_122b2.sh -- sourced by meetings_index_lists_meetings_not_holidays and
# birthday_listed_once_per_person. Stages lib/walk_fixture_122b2.py on the box and runs
# it with the installed pipeline venv (the one that carries the store-auth shim).
#
# Reach the box through box_run, never directly: a probe that stats a path or runs
# python itself measures the DRIVER. box_run drops stderr, so every command here
# ends in ONE answer line and wf_py says CANNOT on silence.

WF_DIR_REL=".ostler/walk-seed/fixture-122b2"

wf_stage_and_run() { # $1 kind (meetings|bday), $2 command; prints the last line the box said
    local here b64 wm64
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    b64="$(base64 < "${here}/walk_fixture_122b2.py" | tr -d '\n')"
    wm64="$(base64 < "${here}/wow_moments.py" | tr -d '\n')"
    box_run "D=\$HOME/${WF_DIR_REL}; PY=\$HOME/.ostler/import-pipeline/.venv/bin/python
[ -x \$PY ] || { echo no-pipeline-venv; exit 0; }
mkdir -p \$D && printf %s '${b64}' | base64 -d > \$D/walk_fixture_122b2.py && printf %s '${wm64}' | base64 -d > \$D/wow_moments.py || { echo stage-failed; exit 0; }
\$PY -W ignore \$D/walk_fixture_122b2.py $1 $2 2>/dev/null | tail -n 1" | tail -n 1
}

wf_cleanup_stage() {
    box_run "rm -rf \$HOME/${WF_DIR_REL}; rmdir \$HOME/.ostler/walk-seed 2>/dev/null; echo done" >/dev/null
}

# wf_json_field <json> <field> -> value or empty
wf_json_field() {
    printf '%s' "$1" | /usr/bin/python3 -I -c 'import json,sys
try: print(json.loads(sys.stdin.read())[sys.argv[1]])
except Exception: pass' "$2"
}

# wf_judge <function> <args...> -> "state<TAB>detail", through the SAME module the box runs.
wf_judge() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    /usr/bin/python3 -I -c 'import sys, importlib.util
spec = importlib.util.spec_from_file_location("wf", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
fn, args = sys.argv[2], sys.argv[3:]
if fn == "judge_meetings":
    s, d = m.judge_meetings(open(args[0]).read(), expect_holiday=(args[1] == "1"))
elif fn == "judge_brief_birthday":
    s, d = m.judge_brief_birthday(open(args[0]).read())
elif fn == "judge_birthday":
    n = lambda x: None if x in ("", "None") else int(x)
    s, d = m.judge_birthday(n(args[0]), n(args[1]))
elif fn == "delivery_is_silent":
    import json
    s, d = ("silent" if m.delivery_is_silent(json.loads(args[0])) else "REFUSED"), ""
print("%s\t%s" % (s, d))' "${here}/walk_fixture_122b2.py" "$@"
}
