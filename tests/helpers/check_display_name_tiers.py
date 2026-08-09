#!/usr/bin/env python3
"""v1018-D658 behavioural check, driven by tests/test_display_name_tiers.sh.

THE DEFECT. Ingest creates a person from a raw handle (a phone number, a
JID) and uses that handle AS the displayName, flagging it
`displayNameProvisional` -- "replace me when a real name arrives". A real
name later arrives from another source and NOTHING retracts anything, so
the node accumulates both. On the founder box 43 person nodes carry two
names and 5 rendered wiki pages show one person's identity on another
person's page.

Root cause, confirmed by reading every write site: all five displayName
writes sit inside an ``if not _person_exists(uri)`` branch. No code path
in the module ever updated an existing person's name, so the flag was
never going to be retracted by anything.

ANDY'S RULING, 2026-08-10, which this asserts:

    tier 0  "+852 1234 5678"       replaces nothing
    tier 1  "j.smith@company.com"  replaces tier 0
    tier 2  "Jane Smith"           replaces tier 0 or 1

An email IS worth writing over a phone -- the domain gives the company and
the local-part usually gives surname-plus-initial -- but it is an
IMPROVEMENT, not a RESOLUTION, so the provisional flag STAYS SET at tier 1
and clears only at tier 2.

This lifts the shipped functions and executes them against a stub
``_sparql_update`` so the ACTUAL generated SPARQL is asserted, not a grep
for the presence of a helper.

Emits one `PASS: ` / `FAIL: ` line per assertion. Never a raw traceback.
"""

from __future__ import annotations

import pathlib
import re
import sys


def fail(msg: str) -> None:
    print("FAIL: " + msg)
    sys.exit(1)


def load_shipped(repo: pathlib.Path) -> dict:
    """Exec the tier block + upsert from the SHIPPED vendored source.

    Extraction is bounded by each function's own end so a runaway regex
    cannot silently swallow the rest of the module -- the v1018-D032
    lesson.
    """
    src_path = repo / "vendor/ostler_fda/pwg_ingest.py"
    if not src_path.exists():
        fail(f"shipped module missing at {src_path}")
    src = src_path.read_text(encoding="utf-8")

    consts = re.search(r"^_NAME_TIER_PLACEHOLDER = .*?^_NAME_TIER_NAME = \d+$",
                       src, re.S | re.M)
    tier_fn = re.search(r"^def _display_name_tier\(.*?(?=^def |\Z)", src, re.S | re.M)
    upsert = re.search(r"^def _upsert_display_name\(.*?(?=^def |\Z)", src, re.S | re.M)
    for name, m in (("tier constants", consts), ("_display_name_tier", tier_fn),
                    ("_upsert_display_name", upsert)):
        if not m:
            fail(f"{name} is gone from the shipped module (v1018-D658)")
    for leaked in ("def ingest_", "def _person_exists"):
        if leaked in tier_fn.group(0) or leaked in upsert.group(0):
            fail(f"extraction overshot and pulled in {leaked!r}")

    captured: list[str] = []

    class _Log:
        def debug(self, *a, **k):
            pass

    ns: dict = {
        "_sparql_update": lambda q: captured.append(q),
        "_escape": lambda v: str(v).replace('"', '\\"'),
        "logger": _Log(),
    }
    exec(consts.group(0) + "\n" + tier_fn.group(0) + "\n" + upsert.group(0), ns)
    ns["_captured"] = captured
    return ns


def main(repo_str: str) -> int:
    ns = load_shipped(pathlib.Path(repo_str))
    tier = ns["_display_name_tier"]
    upsert = ns["_upsert_display_name"]
    cap = ns["_captured"]
    PLACEHOLDER, HANDLE, NAME = (
        ns["_NAME_TIER_PLACEHOLDER"], ns["_NAME_TIER_HANDLE"], ns["_NAME_TIER_NAME"],
    )

    checks: list[tuple[str, bool]] = []

    # --- the tier table, which IS Andy's ruling ------------------------
    for label, value, want in [
        ("intl phone is tier 0", "+852 1234 5678", PLACEHOLDER),
        ("national phone is tier 0", "07700 900123", PLACEHOLDER),
        ("bare digits are tier 0", "85212345678", PLACEHOLDER),
        ("empty is tier 0", "", PLACEHOLDER),
        ("whitespace is tier 0", "   ", PLACEHOLDER),
        ("email is tier 1", "j.smith@company.com", HANDLE),
        ("email with subdomain is tier 1", "a.b@mail.company.co.uk", HANDLE),
        ("human name is tier 2", "Jane Smith", NAME),
        ("single-word name is tier 2", "Madonna", NAME),
        ("name with a digit is tier 2", "Jane Smith 2", NAME),
    ]:
        checks.append((label, tier(value) == want))

    # --- the guard actually emitted, per tier --------------------------
    # A grep for the helper proves nothing; these assert the SPARQL.
    def sparql_for(value: str) -> str:
        cap.clear()
        upsert("urn:p", value)
        if len(cap) != 1:
            fail(f"expected exactly 1 SPARQL update for {value!r}, got {len(cap)}")
        return cap[0]

    q_name = sparql_for("Jane Smith")
    q_mail = sparql_for("j.smith@company.com")
    q_phone = sparql_for("+852 1234 5678")

    checks.append((
        "a real name may replace anything still provisional",
        "!BOUND(?old) || BOUND(?prov)" in q_name,
    ))
    checks.append((
        "an email may replace ONLY a non-email placeholder",
        'BOUND(?prov) && !CONTAINS(STR(?old), "@")' in q_mail,
    ))
    checks.append((
        "a phone never overwrites an existing name",
        "FILTER (!BOUND(?old))" in q_phone,
    ))

    # --- the flag: the half that is easy to get wrong ------------------
    flag = 'pwg:displayNameProvisional "true"'
    checks.append((
        "a real name CLEARS the provisional flag",
        flag not in q_name.split("WHERE")[0].split("INSERT")[1],
    ))
    checks.append((
        "an email KEEPS the provisional flag (improvement, not resolution)",
        flag in q_mail.split("WHERE")[0].split("INSERT")[1],
    ))
    checks.append((
        "every tier deletes the old flag so it cannot be orphaned",
        all("pwg:displayNameProvisional ?prov" in q.split("INSERT")[0]
            for q in (q_name, q_mail, q_phone)),
    ))
    checks.append((
        "every tier deletes the old displayName rather than adding a second",
        all("pwg:displayName ?old" in q.split("INSERT")[0]
            for q in (q_name, q_mail, q_phone)),
    ))

    # --- no same-tier churn --------------------------------------------
    # Two emails must not fight over the same node forever.
    checks.append((
        "email does not replace another email",
        '!CONTAINS(STR(?old), "@")' in q_mail,
    ))

    rc = 0
    for label, good in checks:
        print(("PASS: " if good else "FAIL: ") + label)
        if not good:
            rc = 1
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 2:
        fail("usage: check_display_name_tiers.py <repo-root>")
    try:
        sys.exit(main(sys.argv[1]))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        fail(f"{type(exc).__name__}: {exc}")
