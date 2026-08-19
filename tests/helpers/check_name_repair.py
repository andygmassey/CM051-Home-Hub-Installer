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

import json
import os
import pathlib
import re
import sys


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def load(repo: pathlib.Path):
    ing = (repo / "vendor/ostler_fda/pwg_ingest.py").read_text(encoding="utf-8")
    rep = (repo / "vendor/ostler_fda/repair_placeholder_names.py").read_text(encoding="utf-8")

    # The whole name rule in one slice -- kinship list, kinship
    # predicates and tier constants. Taking it whole is what makes this
    # gate test the SHIPPED rule rather than a restatement of it.
    consts = re.search(r"^_KINSHIP_DEFAULT = .*?^_NAME_TIER_NAME = \d+$", ing, re.S | re.M)
    tier = re.search(r"^def _display_name_tier\(.*?(?=^def |\Z)", ing, re.S | re.M)
    fold = re.search(r"^def _fold\(.*?(?=^def |\Z)", rep, re.S | re.M)
    dec = re.search(r"^def decide\(.*?(?=^# ──|\Z)", rep, re.S | re.M)
    for name, m in (("the name-rule block", consts), ("_display_name_tier", tier),
                    ("_fold", fold), ("decide", dec)):
        if not m:
            fail(f"{name} not found in the shipped source (v1018-D658/D659)")

    ns: dict = {"re": re, "os": os, "json": json, "Dict": dict, "List": list,
                "Tuple": tuple, "Sequence": list}
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

    KIN = "Mum"

    # --- the automatic cases -------------------------------------------
    keep, demote, gone, clear, verdict = decide([PHONE, NAME])
    checks.append(("a real name beats a phone", keep == NAME and demote == [PHONE]))
    checks.append(("...and the phone is returned for DEMOTION, not loss",
                   demote == [PHONE] and gone == []))
    checks.append(("...and clears the provisional flag", clear is True))
    checks.append(("...and is automatic", verdict == "auto"))

    keep, demote, gone, clear, verdict = decide([PHONE, MAIL])
    checks.append(("an email beats a phone", keep == MAIL and demote == [PHONE]))
    checks.append(("...and KEEPS the flag (improvement, not resolution)", clear is False))

    keep, demote, gone, clear, _ = decide([PHONE, MAIL, NAME])
    checks.append(("a real name beats both, demoting both",
                   keep == NAME and sorted(demote) == sorted([PHONE, MAIL]) and clear))

    # --- v1018-D659: a kinship word is DELETED, never demoted -----------
    # An alternateName is offered to the assistant as another name this
    # person goes by, so demoting "Mum" onto Andy's wife still lets it
    # answer "your mum is <wife>". His mother has died.
    keep, demote, gone, clear, verdict = decide([KIN, NAME])
    checks.append(("a kinship word never survives beside a real name", keep == NAME))
    checks.append(("...it is DELETED, not demoted to alternateName",
                   gone == [KIN] and demote == []))
    checks.append(("...and there is work to do, so it is not 'single'",
                   verdict == "auto"))

    keep, demote, gone, clear, verdict = decide([KIN, PHONE])
    checks.append(("a kinship word does not beat even a phone number",
                   keep == PHONE and gone == [KIN]))
    checks.append(("...and a surviving phone does NOT clear the flag", clear is False))

    keep, demote, gone, clear, verdict = decide([KIN, NAME, NAME2])
    checks.append(("a drop still happens when the election is unresolvable",
                   verdict == "review" and gone == [KIN] and keep is None))

    keep, demote, gone, clear, verdict = decide([KIN])
    checks.append(("the LAST name is never deleted, even a kinship word",
                   verdict == "review" and gone == [] and keep is None))

    # --- THE OVER-REFUSAL DIRECTION, which is the one with teeth ---------
    # TNM, 2026-08-10, reviewing this pair: "the failure mode of an
    # over-eager kinship guard is silently deleting a real person's only
    # label. That wants a demonstrated RED on the KEEP case, not just the
    # DROP case."
    #
    # He is right and this file did not have it. #550 refusing to WRITE a
    # name is recoverable -- nothing is lost. THIS module DELETES, so a
    # predicate that over-matches here destroys a real person's name with
    # no undo. Every one of these carries a real name and must never be
    # droppable, however kinship-adjacent it looks.
    #
    # All nine are SYNTHETIC, built around the substring each has to
    # survive. Only the SHAPE is load-bearing -- "Auntie Wren" proves
    # exactly what a real aunt's name would prove -- so there is no reason
    # for a real contact to appear here, and grepping this file for one
    # finds nothing.
    #
    #   Auntie/Granny/Mum/Nan/Papa/Mother   kinship word + a name
    #   Motherwell "mother"   Jameson "son"   Kidwell "kid"
    #   Grant "gran"          Boyd "boy"
    for label in ["Auntie Wren", "Granny Fairholm", "Mum Chen", "Nan Whitfield",
                  "Papa Okonkwo", "Mother Bexley", "Jane Motherwell",
                  "Jameson Kidwell", "Grant Boyd"]:
        k, d, g, c, v = decide([label, PHONE])
        checks.append(("a real name is never deleted: %r" % label,
                       g == [] and k == label))
    # And the same names must survive as the SOLE label on a node.
    for label in ["Auntie Emma", "Mum Zhang", "Sonia Kidd"]:
        k, d, g, c, v = decide([label])
        checks.append(("sole real name is never deleted: %r" % label,
                       g == [] and k == label))

    # --- THE NEGATIVE, which is the whole point -------------------------
    for label, names in [
        ("two real names are NEVER auto-resolved", [NAME, NAME2]),
        ("two emails are never auto-resolved", [MAIL, MAIL2]),
        ("two phones are never auto-resolved", [PHONE, PHONE2]),
        ("a near-duplicate pair is NOT collapsed (Andy: review list)",
         ["Bob", "Bob Chen"]),
        ("three-way tie is never auto-resolved", [NAME, NAME2, "Ada Lovelace"]),
    ]:
        k, d, g, c, v = decide(names)
        checks.append((label, v == "review" and d == [] and g == []
                       and k is None and c is False))

    # --- folding: same name written twice is not a conflict -------------
    k, d, g, c, v = decide(["Jane Smith", "jane  smith"])
    checks.append(("case/space variants of one name collapse to 'single'", v == "single"))
    checks.append(("...and demote nothing", d == []))
    k, d, g, c, v = decide(["Jane Smith", "Jane Smith."])
    checks.append(("trailing punctuation is not a second name", v == "single"))

    # --- degenerate input ------------------------------------------------
    checks.append(("no names at all is safe", decide([])[4] == "single"))
    checks.append(("one name is 'single' and demotes nothing", decide([NAME])[1] == []))
    k, d, g, c, v = decide([PHONE])
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
