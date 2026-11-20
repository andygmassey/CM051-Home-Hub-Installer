"""CB137 people-row service gate: only a PERSON card exempts a row.

ical-server.py is hyphenated and not importable (see test_timeline_sources.py).
This test extracts people_row_hidden_as_service and the helpers it needs from
the source with ast, and executes exactly those definitions. No server, no
Qdrant, no Oxigraph.

Archie ruling 2026-11-20:
  - a PERSON card the owner made shows, whatever its name looks like;
  - an organisation card (contact_type "business") is excluded;
  - a name-only row, or a row with given/family names and no person card,
    gets the service checks (a given/family name alone is not proof of a person).

Mutant: exempt every carded row whatever its contact_type, and the service
case goes red.
"""

from __future__ import annotations

import ast
import pathlib
import re

import pytest

SERVER_PY = pathlib.Path(__file__).resolve().parents[1] / "ical-server.py"
PEOPLE_RULES_DIR = SERVER_PY.parent
TARGET = "people_row_hidden_as_service"


def _load_gate(source: str | None = None):
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
    needed, todo = set(), [TARGET]
    while todo:
        n = todo.pop()
        if n in needed or n not in defs:
            continue
        needed.add(n)
        for sub in ast.walk(defs[n]):
            if isinstance(sub, ast.Name) and sub.id in defs:
                todo.append(sub.id)
    body = [defs[n] for n in defs if n in needed]
    module = ast.Module(body=body, type_ignores=[])
    ast.fix_missing_locations(module)
    ns = {"re": re}
    # The helpers the gate calls come from people_rules.py (the server imports them).
    import sys
    if str(PEOPLE_RULES_DIR) not in sys.path:
        sys.path.insert(0, str(PEOPLE_RULES_DIR))
    import people_rules
    for k in dir(people_rules):
        if k.startswith("_is_"):
            ns[k] = getattr(people_rules, k)
    exec(compile(module, str(SERVER_PY), "exec"), ns)
    return ns[TARGET]


gate = _load_gate()

# Synthetic names only.
SERVICE_NAME = "acme payment notification team"          # service phrasing
SERVICE_MAILBOX = "orders@example-shop.test"         # service mailbox shape
PLAIN_PERSON = "Jane Doe"


def test_a_person_card_with_a_service_like_name_shows_as_a_person():
    assert gate(SERVICE_NAME, has_card=True, contact_type="person") is False


def test_an_organisation_card_is_excluded():
    assert gate("acme widgets", has_card=True, contact_type="business") is True


def test_a_name_only_service_sender_is_excluded():
    assert gate(SERVICE_NAME, has_card=False, contact_type=None) is True
    assert gate(SERVICE_MAILBOX, has_card=False, contact_type=None) is True


def test_a_named_row_without_a_person_card_gets_the_service_check():
    # given/family names are not an argument at all: the gate sees only the card.
    assert gate(SERVICE_NAME, has_card=False, contact_type="unclassified") is True


def test_an_unclassified_card_does_not_exempt_a_service_name():
    assert gate(SERVICE_NAME, has_card=True, contact_type="unclassified") is True


def test_a_real_person_still_shows():
    assert gate(PLAIN_PERSON, has_card=False, contact_type=None) is False
    assert gate(PLAIN_PERSON, has_card=True, contact_type="person") is False


def test_mutant_exempting_every_carded_row_is_caught():
    # Mutant: any carded row is exempt, whatever its contact_type. The real gate
    # must catch the difference on an unclassified card with a service name.
    real_src = SERVER_PY.read_text(encoding="utf-8")
    old = '    if has_card and contact_type == "person":\n        return False\n'
    assert real_src.count(old) == 1, "gate source changed; update the mutant"
    mutant = _load_gate(real_src.replace(old, "    if has_card:\n        return False\n"))
    assert mutant(SERVICE_NAME, has_card=True, contact_type="unclassified") is False
    assert gate(SERVICE_NAME, has_card=True, contact_type="unclassified") is True
