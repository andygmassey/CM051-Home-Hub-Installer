#!/usr/bin/env python3
"""lib/transcription_consent_rules.csv must fail toward asking, never toward assuming.

WHY THIS FILE EXISTS AS DATA AND NOT AS A PYTHON LITERAL. The country list was
a frozenset inside ical-server.py, which made a LEGAL determination into a code
edit: a stray comma is a SyntaxError that takes out everything that file powers,
and reviewing it means reading Python. This repo has already lost a day to
exactly that shape, when one character in a table inside a source file killed
the site. As data, a solicitor can read and edit it and a change reviews as one
line per country.

THE PROPERTY THAT MATTERS, AND IT IS NOT "THE FILE PARSES". A consent table can
be well-formed and still dangerous in one specific direction: answering
PERMISSIVELY for a place it does not actually know about. The Hub resolves a
device REGION, which yields a country and never a state. So a country that has
sub-national variation must NOT carry a permissive country-level answer, or a
customer in California matches the US row, reads "one party is enough", and the
strict path never fires.
"""
import csv
import pathlib
import sys

REPO = pathlib.Path(__file__).resolve().parents[1]
CSV_PATH = REPO / "lib" / "transcription_consent_rules.csv"
VALID = {"yes", "no", "unclear"}

fails = []


def bad(msg):
    print(f"  FAIL  {msg}")
    fails.append(msg)


def ok(msg):
    print(f"  PASS  {msg}")


def load(path):
    text = path.read_text(encoding="utf-8")
    body = "\n".join(ln for ln in text.split("\n") if not ln.startswith("#"))
    return list(csv.DictReader(body.splitlines()))


def main():
    if not CSV_PATH.exists():
        print("CANNOT-RUN: the table is missing. That is NOT a pass: a consent")
        print("            decision with no table behind it is the thing this guards.")
        return 2

    rows = load(CSV_PATH)
    if len(rows) < 100:
        # A zero denominator reads as success. So does a nearly-zero one.
        print(f"CANNOT-RUN: only {len(rows)} row(s) parsed. The table covers every ISO")
        print("            country, so a short read means the parse broke rather than")
        print("            the world shrinking.")
        return 2
    print(f"examined {len(rows)} row(s).")

    # ---- SELF-TEST FIRST -------------------------------------------------
    # Each check is handed a specimen it MUST reject. A check that cannot go
    # red would report a clean sheet for a dangerous table.
    print("self-test: every check must reject its own specimen")
    specimen = [
        {"iso": "US", "country": "x", "all_party": "no", "source": "s",
         "decided_on": "2026-09", "decided_by": "d"},
        {"iso": "US-CA", "country": "x", "all_party": "yes", "source": "s",
         "decided_on": "2026-09", "decided_by": "d"},
    ]
    if permissive_parents(specimen):
        print("  ok    the sub-national check rejects a permissive parent")
    else:
        print("  BLIND the sub-national check passed a permissive parent. Refusing.")
        return 1
    if not permissive_parents([dict(specimen[0], all_party="unclear"), specimen[1]]):
        print("  ok    and it accepts the same table once the parent is unclear")
    else:
        print("  BLIND it flags a table that is already correct. Refusing.")
        return 1

    # ---- THE REAL CHECKS -------------------------------------------------
    print("\nthe table as committed:")

    vals = {r["all_party"] for r in rows}
    if vals <= VALID:
        ok(f"every all_party value is one of {sorted(VALID)}")
    else:
        bad(f"values outside the vocabulary: {sorted(vals - VALID)}")

    isos = [r["iso"] for r in rows]
    dupes = sorted({i for i in isos if isos.count(i) > 1})
    if not dupes:
        ok(f"every one of the {len(isos)} iso codes is unique")
    else:
        bad(f"duplicate iso codes, so a lookup depends on row order: {dupes}")

    offenders = permissive_parents(rows)
    if not offenders:
        ok("no country with sub-national rows carries a permissive country-level answer")
    else:
        bad("these countries have sub-national variation AND a permissive country-level "
            f"answer, so the strict path never fires for their strict states: {offenders}")

    missing = [r["iso"] for r in rows if not r.get("source", "").strip()]
    if not missing:
        ok("every row cites a source")
    else:
        bad(f"{len(missing)} row(s) assert a legal position with no source: {missing[:8]}")

    undated = [r["iso"] for r in rows if not r.get("decided_on", "").strip()]
    if not undated:
        ok("every row is dated, so staleness is visible")
    else:
        bad(f"{len(undated)} row(s) carry no date")

    # The provenance must be legible as what it is. A row that reads like a
    # firm's advice when it is two language models is the kind of thing nobody
    # questions six months later.
    text = CSV_PATH.read_text(encoding="utf-8")
    if "NOT LEGAL ADVICE" in text.upper():
        ok("the file states in its own header that it is not legal advice")
    else:
        bad("the header does not say this is not legal advice")

    # ---- the escalation column cannot rot into a lie --------------------
    derived = {r["iso"].split("-")[0] for r in rows if "-" in r["iso"]}
    declared = {r["iso"] for r in rows if r.get("needs_finer") == "yes"}
    if declared == derived:
        ok(f"needs_finer matches the iso codes exactly ({len(declared)} country/countries)")
    else:
        bad(f"needs_finer disagrees with the iso codes. declared-only={sorted(declared - derived)} "
            f"derived-only={sorted(derived - declared)}. A country whose law varies below the "
            f"country but is not flagged gets a country-level answer applied to states it is "
            f"wrong for.")

    # ---- the reader must never be permissive about what it does not know --
    sys.path.insert(0, str(REPO / "lib"))
    try:
        import ostler_consent_jurisdiction as juris
    except ImportError as e:
        print(f"  CANNOT-RUN  the reader could not be imported: {e!r}")
        print(f"\n{8 - len(fails)} passed, {len(fails)} failed, 1 could not run, denominator 9")
        return 1

    table = juris.load(CSV_PATH)
    unknown = [juris.resolve(x, table) for x in ("ZZ", "", None, "US-ZZ", "not-an-iso")]
    if all(v == "unclear" for v, _ in unknown):
        ok("the reader answers `unclear` for every unknown code, never `no`")
    else:
        bad(f"the reader gave a non-unclear answer for an unknown code: {unknown}")

    # A predicate that always says "ask" is safe and useless, and reads
    # identically to a correct one. It must be able to say no.
    one_party = [r["iso"] for r in rows if r["all_party"] == "no"]
    says_no = [i for i in one_party if not juris.must_ask_everyone(i, table)]
    if one_party and len(says_no) == len(one_party):
        ok(f"CONTROL: must_ask_everyone returns False for all {len(one_party)} recorded "
           f"one-party places, so it is not a stuck predicate")
    else:
        bad(f"must_ask_everyone returned True for {len(one_party) - len(says_no)} of "
            f"{len(one_party)} one-party places. A predicate that cannot say no is "
            f"indistinguishable from one that is broken.")

    print(f"\n{9 - len(fails)} passed, {len(fails)} failed, denominator 9")
    return 1 if fails else 0


def permissive_parents(rows):
    """Countries that have sub-national rows AND a non-strict country-level row."""
    sub = {r["iso"].split("-")[0] for r in rows if "-" in r["iso"]}
    return sorted(r["iso"] for r in rows
                  if r["iso"] in sub and r["all_party"] != "unclear")


if __name__ == "__main__":
    sys.exit(main())
