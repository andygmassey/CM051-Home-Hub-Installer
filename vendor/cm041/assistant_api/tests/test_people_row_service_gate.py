"""CB137 people-row service gate, Archie's final ruling 2026-11-20.

- A business card is always hidden. A PERSON card the owner made always shows.
- A row with a given or family name and no person card is hidden ONLY on positive
  service evidence: a role or no-reply mailbox address, or a service phrase from the
  existing list. Name shape alone never excludes ("JANE DOE", "Alex Doe - Plumber").
- An unnamed row keeps the organisation and service-shape checks.

ical-server.py is hyphenated and not importable, so the gate and the helpers it
calls are extracted with ast and executed. Mutant: exclude a named row on name shape,
and the name-shape tests go red.
"""
from __future__ import annotations

import ast
import pathlib
import re

SERVER_PY = pathlib.Path(__file__).resolve().parents[1] / "ical-server.py"
TARGETS = ("people_row_hidden_as_service", "_named_row_has_service_evidence")


def _load(source: str | None = None):
    src = source if source is not None else SERVER_PY.read_text(encoding="utf-8")
    tree = ast.parse(src)
    defs = {}
    for node in tree.body:
        if isinstance(node, ast.FunctionDef):
            defs[node.name] = node
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                if isinstance(t, ast.Name):
                    defs[t.id] = node
    needed, todo = set(), list(TARGETS)
    while todo:
        n = todo.pop()
        if n in needed or n not in defs:
            continue
        needed.add(n)
        for sub in ast.walk(defs[n]):
            if isinstance(sub, ast.Name) and sub.id in defs:
                todo.append(sub.id)
    body = [defs[n] for n in defs if n in needed]
    ns = {"re": re}
    import sys
    rules_dir = str(SERVER_PY.parent)
    if rules_dir not in sys.path:
        sys.path.insert(0, rules_dir)
    import people_rules
    for k in dir(people_rules):
        if k.startswith("_"):
            ns[k] = getattr(people_rules, k)
    exec(compile(ast.Module(body=body, type_ignores=[]), str(SERVER_PY), "exec"), ns)
    return ns["people_row_hidden_as_service"]


gate = _load()
AT = "@"


def test_a_business_card_is_hidden():
    assert gate("acme widgets", has_card=True, contact_type="business") is True


def test_a_person_card_shows_whatever_its_name_looks_like():
    assert gate("acme notification team", has_card=True, contact_type="person") is False


def test_a_named_row_with_a_noreply_address_and_no_card_is_excluded():
    assert gate("Ben Carl", has_card=False, contact_type=None, named=True,
                addresses=["noreply" + AT + "example.co.uk"]) is True


def test_a_named_row_with_a_service_phrase_is_excluded():
    assert gate("acme notification team", has_card=False, contact_type=None, named=True) is True


def test_a_named_row_with_name_shape_alone_is_kept():
    # name shape only: all caps, and a role after a dash. Neither is evidence.
    assert gate("BOB DOE", has_card=False, contact_type=None, named=True) is False
    assert gate("Alex Doe - Plumber", has_card=False, contact_type=None, named=True) is False


def test_an_unnamed_service_sender_is_excluded():
    assert gate("acme notification team", has_card=False, contact_type=None, named=False) is True


def test_mutant_excluding_a_named_row_on_name_shape_is_caught():
    real = SERVER_PY.read_text(encoding="utf-8")
    old = "    if named:\n        return _named_row_has_service_evidence(name, addresses)\n"
    assert real.count(old) == 1, "gate source changed; update the mutant"
    mutant = _load(real.replace(old, (
        "    if named:\n"
        "        return bool(_is_automated_or_service_name(name) or _is_service_mailbox_name(name))\n")))
    # the mutant excludes a name-shape-only row, the shipped gate keeps it
    assert mutant("BOB DOE", has_card=False, contact_type=None, named=True) is True
    assert gate("BOB DOE", has_card=False, contact_type=None, named=True) is False
