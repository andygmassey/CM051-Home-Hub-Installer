"""S9 row 3: a bare Instagram handle must not become a person's name.

The module imports the resolver stack at top level, so the pure function is
compiled out of the real source file (both shipped copies) instead of imported.
"""
import ast
import pathlib

import pytest

ROOT = pathlib.Path(__file__).resolve().parents[2]
COPIES = ["contact_syncer/instagram_social.py", "vendor/cm041/contact_syncer/instagram_social.py"]


def _fn(rel):
    src = (ROOT / rel).read_text()
    node = next(n for n in ast.parse(src).body
                if isinstance(n, ast.FunctionDef) and n.name == "_username_to_display_name")
    ns = {}
    exec(compile(ast.Module([node], []), rel, "exec"), ns)
    return ns["_username_to_display_name"]


@pytest.mark.parametrize("rel", COPIES)
def test_bare_handle_stays_a_handle(rel):
    assert _fn(rel)("examplehandle") == "@examplehandle"


@pytest.mark.parametrize("rel", COPIES)
def test_separated_handle_still_reads_as_a_name(rel):
    assert _fn(rel)("alex.example") == "Alex Example"
    assert _fn(rel)("alex.example.779") == "Alex Example"
