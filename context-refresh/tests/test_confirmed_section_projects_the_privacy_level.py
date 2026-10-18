"""The "Confirmed by you" query must RETURN ?level, or its L3 filter is blind.

v1.0.107: the query bound ?level in an OPTIONAL clause but did not project it,
so row.get("level") was always None, _is_withheld(None) was False, and L3
(most private) user-asserted facts were written into CONTEXT.md, which is
injected into every chat prompt.
"""
import re
from pathlib import Path

SRC = (Path(__file__).resolve().parents[1] / "bin" / "generate_pwg_context.py").read_text()


def test_every_select_that_filters_on_level_also_returns_it():
    checked = 0
    for m in re.finditer(r"SELECT ([^\n]*?) WHERE \{\{", SRC):
        body = SRC[m.end():m.end() + 900]
        uses_level = "?level" in body.split("SELECT", 1)[0]
        if uses_level:
            checked += 1
            assert "?level" in m.group(1), f"SELECT {m.group(1)!r} filters on ?level but never returns it"
    assert checked >= 2, f"expected at least 2 level-filtered SELECTs, examined {checked}"
