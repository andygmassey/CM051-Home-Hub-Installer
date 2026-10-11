"""people_rules.py is the single source of the People list rules and is
imported by two interpreters (ical-server's venv and cm048's own). It must
therefore import nothing outside the standard library, and must not depend
on any global it does not define.

Also pins that the People behaviour did not change when the rules moved out
of ical-server.py: a golden table generated from the PRE-move ical-server.py
(origin/main before this change) is replayed through both the new module and
the new ical-server.py's re-exports.
"""
from __future__ import annotations

import ast
import builtins
import importlib.util
import json
import os
import sys
import symtable
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
API = ROOT / "vendor" / "cm041" / "assistant_api"
RULES = API / "people_rules.py"
GOLDEN = json.loads((ROOT / "tests" / "fixtures" / "people_rules_golden.json").read_text())


def _load_rules():
    spec = importlib.util.spec_from_file_location("_people_rules_under_test", RULES)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_imports_only_the_standard_library():
    tree = ast.parse(RULES.read_text())
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            found += [a.name.split(".")[0] for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            assert node.level == 0, "relative import in people_rules.py"
            found.append((node.module or "").split(".")[0])
    assert found, "anti-vacuity: the file imports at least `re`"
    bad = [m for m in found if m not in sys.stdlib_module_names]
    assert not bad, "people_rules.py imports outside the stdlib: %s" % bad


def test_it_runs_in_an_interpreter_with_nothing_else_on_the_path():
    """Import it in a fresh interpreter with -I (no site, no cwd, no env)."""
    import subprocess

    r = subprocess.run(
        [sys.executable, "-I", "-c",
         "import importlib.util,sys;s=importlib.util.spec_from_file_location('r',sys.argv[1]);"
         "m=importlib.util.module_from_spec(s);s.loader.exec_module(m);"
         "print(m._is_nameless_name('+15550100'), m._is_nameless_name('Jane Doe'))",
         str(RULES)],
        capture_output=True, text=True, timeout=60,
    )
    assert r.returncode == 0, r.stderr[-400:]
    assert r.stdout.split() == ["True", "False"]


def test_no_function_reaches_a_global_the_module_does_not_define():
    src = RULES.read_text()
    top = symtable.symtable(src, str(RULES), "exec")
    defined = {s.get_name() for s in top.get_symbols() if s.is_assigned() or s.is_imported()}
    defined |= {"__name__", "__file__", "__doc__"}
    missing = []

    def walk(tab):
        for s in tab.get_symbols():
            if tab.get_type() == "function" and s.is_global() and s.is_referenced():
                n = s.get_name()
                if n not in defined and not hasattr(builtins, n):
                    missing.append((tab.get_name(), n))
        for child in tab.get_children():
            walk(child)

    walk(top)
    assert not missing, "undefined globals: %s" % missing


def test_the_rules_are_defined_once_not_copied_back_into_ical_server():
    ical = (API / "ical-server.py").read_text()
    for n in ("_is_nameless_name", "_is_non_human_person", "_ORG_STRONG_RE", "_ORG_WEAK_RE"):
        assert "def %s(" % n not in ical and ("%s = " % n) not in ical, n
    assert "from people_rules import" in ical


def test_behaviour_is_unchanged_by_the_move_for_every_golden_row():
    m = _load_rules()
    checked = 0
    for fn, rows in GOLDEN["single"].items():
        for name, want in rows:
            assert getattr(m, fn)(name) == want, (fn, name)
            checked += 1
    for name, payload, phones, emails, want in GOLDEN["nonhuman"]:
        got = m._is_non_human_person(payload, name) if phones is None else m._is_non_human_person(payload, name, phones, emails)
        assert got == want, (name, payload, phones, emails)
        checked += 1
    assert checked > 1000, checked
    assert any(r[-1] for r in GOLDEN["nonhuman"]) and any(not r[-1] for r in GOLDEN["nonhuman"])


def test_ical_server_re_exports_the_same_functions():
    """ical-server.py must expose the SAME function objects (so its callers,
    and test monkeypatching of ical-server names, are unchanged)."""
    os.environ.setdefault("OSTLER_SERVICE_TOKEN", "test-only-people-rules")
    spec = importlib.util.spec_from_file_location("_ical_for_rules", API / "ical-server.py")
    srv = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(API))
    try:
        spec.loader.exec_module(srv)
    finally:
        sys.path.remove(str(API))
    import people_rules as pr  # the module ical-server itself imported

    for n in ("_is_nameless_name", "_is_non_human_person", "_is_automated_or_service_name"):
        assert getattr(srv, n) is getattr(pr, n), n


def test_the_golden_table_still_reaches_every_branch_it_used_to():
    """Anti-shrink: the replay must execute at least as many lines of
    people_rules.py as the table it replaced (147), so thinning the table
    cannot quietly stop it pinning a branch."""
    m = _load_rules()
    hit = set()
    fn = str(RULES)

    def tr(frame, ev, arg):
        if frame.f_code.co_filename != fn:
            return None

        def lt(f, e, a):
            if e == "line":
                hit.add(f.f_lineno)
            return lt

        hit.add(frame.f_lineno)
        return lt

    sys.settrace(tr)
    try:
        for f, rows in GOLDEN["single"].items():
            for name, _ in rows:
                getattr(m, f)(name)
        for name, payload, phones, emails, _ in GOLDEN["nonhuman"]:
            if phones is None:
                m._is_non_human_person(payload, name)
            else:
                m._is_non_human_person(payload, name, phones, emails)
    finally:
        sys.settrace(None)
    assert len(hit) >= 150, len(hit)
