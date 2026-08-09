#!/usr/bin/env python3
"""v1018-D658 repair-decision check, driven by tests/test_name_repair.sh.

Lifts `decide()` out of the SHIPPED repair module and the tier rule out of
the SHIPPED pwg_ingest, and executes them together. No graph, no network:
the decision is a pure function precisely so it can be tested this way.

The assertion that matters most is the NEGATIVE one -- that a tie returns
NO drops. Andy's call 2026-08-10 was "review list", and a repair that
quietly picks a winner deletes a correct name with no undo.
"""
from __future__ import annotations

import pathlib
import re
import sys


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def load(repo: pathlib.Path):
    ing = (repo / "vendor/ostler_fda/pwg_ingest.py").read_text(encoding="utf-8")
    rep = (repo / "vendor/ostler_fda/repair_placeholder_names.py").read_text(encoding="utf-8")

    consts = re.search(r"^_NAME_TIER_PLACEHOLDER = .*?^_NAME_TIER_NAME = \d+$", ing, re.S | re.M)
    tier = re.search(r"^def _display_name_tier\(.*?(?=^def |\Z)", ing, re.S | re.M)
    fold = re.search(r"^def _fold\(.*?(?=^def |\Z)", rep, re.S | re.M)
    dec = re.search(r"^def decide\(.*?(?=^# ──|\Z)", rep, re.S | re.M)
    for name, m in (("tier constants", consts), ("_display_name_tier", tier),
                    ("_fold", fold), ("decide", dec)):
        if not m:
            fail(f"{name} not found in the shipped source (v1018-D658)")

    ns: dict = {"re": re, "Dict": dict, "List": list, "Tuple": tuple,
                "Sequence": list}
    exec("from __future__ import annotations\n" + consts.group(0) + "\n"
         + tier.group(0) + "\n" + fold.group(0) + "\n" + dec.group(0), ns)
    return ns


def main(repo_str: str) -> int:
    ns = load(pathlib.Path(repo_str))
    decide = ns["decide"]
    checks: list[tuple[str, bool]] = []

    PHONE, PHONE2 = "+852 1234 5678", "+44 7700 900123"
    MAIL, MAIL2 = "j.smith@company.com", "jane@other.co.uk"
    NAME, NAME2 = "Jane Smith", "Robert Chen"

    # --- the automatic cases -------------------------------------------
    keep, drop, clear, verdict = decide([PHONE, NAME])
    checks.append(("a real name beats a phone", keep == NAME and drop == [PHONE]))
    checks.append(("...and clears the provisional flag", clear is True))
    checks.append(("...and is automatic", verdict == "auto"))

    keep, drop, clear, verdict = decide([PHONE, MAIL])
    checks.append(("an email beats a phone", keep == MAIL and drop == [PHONE]))
    checks.append(("...and KEEPS the flag (improvement, not resolution)", clear is False))

    keep, drop, clear, _ = decide([PHONE, MAIL, NAME])
    checks.append(("a real name beats both, dropping both",
                   keep == NAME and sorted(drop) == sorted([PHONE, MAIL]) and clear))

    # --- THE NEGATIVE, which is the whole point -------------------------
    for label, names in [
        ("two real names are NEVER auto-resolved", [NAME, NAME2]),
        ("two emails are never auto-resolved", [MAIL, MAIL2]),
        ("two phones are never auto-resolved", [PHONE, PHONE2]),
        ("a near-duplicate pair is NOT collapsed (Andy: review list)",
         ["Bob", "Bob Chen"]),
        ("three-way tie is never auto-resolved", [NAME, NAME2, "Ada Lovelace"]),
    ]:
        k, d, c, v = decide(names)
        checks.append((label, v == "review" and d == [] and k is None and c is False))

    # --- folding: same name written twice is not a conflict -------------
    k, d, c, v = decide(["Jane Smith", "jane  smith"])
    checks.append(("case/space variants of one name collapse to 'single'", v == "single"))
    checks.append(("...and drop nothing", d == []))
    k, d, c, v = decide(["Jane Smith", "Jane Smith."])
    checks.append(("trailing punctuation is not a second name", v == "single"))

    # --- degenerate input ------------------------------------------------
    checks.append(("no names at all is safe", decide([])[3] == "single"))
    checks.append(("one name is 'single' and drops nothing", decide([NAME])[1] == []))
    k, d, c, v = decide([PHONE])
    checks.append(("a lone phone does NOT get its flag cleared", c is False))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_name_repair.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
