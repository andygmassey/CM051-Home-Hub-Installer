#!/usr/bin/env python3
"""Email-only correspondents get a provisional displayName, and names only move up.

CM051 #2361. The v1.0.102 walk failed people_count_agreement: Oxigraph held
3437 Person nodes and the people index 3409. Exactly 28 had no displayName,
and all 28 had the shape vendor/cm021/src/cli.py _build_upsert writes for a
sender whose From header carries no name. ingest_people_to_qdrant indexes only
Persons with a displayName, so those 28 were in the graph and absent from
search and the wiki.

This EXECUTES the shipped _build_upsert against a real SPARQL engine
(pyoxigraph, the engine the product speaks to) and checks the tier rule
ostler_fda already applies (_upsert_display_name): an email address is tier 1
and written provisional; a human name is tier 2 and clears the flag; names
only ever move up; a real name is never displaced. Synthetic data only.

EXIT CODES   0 all pass   1 a check failed   2 CANNOT-RUN
"""
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CLI = Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "vendor" / "cm021" / "src" / "cli.py"

try:
    import pyoxigraph
except ImportError:
    print("CANNOT-RUN: pyoxigraph is not installed", file=sys.stderr)
    sys.exit(2)

# cli.py imports src.filters and src.parsers.fast_mbox_parser at load time,
# which pull in parser deps this test does not need. Stub exactly those two,
# the same side-load vendor/cm021/tests/test_pwg_namespace.py uses.
import types
_src = types.ModuleType("src"); _src.__path__ = []
sys.modules.setdefault("src", _src)
_f = types.ModuleType("src.filters"); _f.EmailFilter = object
sys.modules.setdefault("src.filters", _f)
_pp = types.ModuleType("src.parsers"); _pp.__path__ = []
sys.modules.setdefault("src.parsers", _pp)
_fp = types.ModuleType("src.parsers.fast_mbox_parser")
_fp.FastEmail = object; _fp.FastMboxParser = object
sys.modules.setdefault("src.parsers.fast_mbox_parser", _fp)

spec = importlib.util.spec_from_file_location("cm021_cli_under_test", CLI)
cli = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(cli)
except Exception as exc:  # the module must import to be measured at all
    print(f"CANNOT-RUN: could not import {CLI}: {exc}", file=sys.stderr)
    sys.exit(2)

NS = cli.PWG_NS
PASS = FAIL = 0


def check(label, cond):
    global PASS, FAIL
    if cond:
        PASS += 1
        print(f"  [PASS] {label}")
    else:
        FAIL += 1
        print(f"  [FAIL] {label}")


def names(store, iri):
    q = f"SELECT ?n WHERE {{ <{iri}> <{NS}displayName> ?n }}"
    return sorted(str(r["n"].value) for r in store.query(q))


def provisional(store, iri):
    q = f"ASK {{ <{iri}> <{NS}displayNameProvisional> ?p }}"
    return bool(store.query(q))


def unnamed_people(store):
    q = (f"SELECT (COUNT(DISTINCT ?p) AS ?n) WHERE {{ ?p a <{NS}Person> "
         f"FILTER NOT EXISTS {{ ?p <{NS}displayName> ?d }} }}")
    return int(next(iter(store.query(q)))["n"].value)


def upsert(store, iri, email, name):
    store.update(cli._build_upsert(iri, email, name, "2031-01-02T03:04:05+00:00"))


A = "https://schema.example/person/a"
B = "https://schema.example/person/b"
C = "https://schema.example/person/c"
D = "https://schema.example/person/d"

s = pyoxigraph.Store()

print("1. a sender with no name")
upsert(s, A, "j.doe@example.com", "")
check("gets the address as its displayName", names(s, A) == ["j.doe@example.com"])
check("and it is marked provisional", provisional(s, A))
check("no Person is left without a displayName (the people index can see it)", unnamed_people(s) == 0)

print("2. the same sender later arrives with a name")
upsert(s, A, "j.doe@example.com", "Jane Doe")
check("the human name replaces the address, one name only", names(s, A) == ["Jane Doe"])
check("and the provisional flag is cleared", not provisional(s, A))

print("3. a later message from that sender with no name")
upsert(s, A, "j.doe@example.com", "")
check("does not demote the human name", names(s, A) == ["Jane Doe"])
check("and does not re-flag it", not provisional(s, A))

print("4. a real name already present and NOT provisional")
s.update(f'INSERT DATA {{ <{B}> a <{NS}Person> ; <{NS}displayName> "John Doe" }}')
upsert(s, B, "john@example.com", "")
check("an address never displaces it", names(s, B) == ["John Doe"])
upsert(s, B, "john@example.com", "Jane Doe")
check("nor does another human name (it is not provisional)", names(s, B) == ["John Doe"])

print("5. a provisional phone-number handle")
s.update(f'INSERT DATA {{ <{C}> a <{NS}Person> ; <{NS}displayName> "+44 7700 900123" ; '
         f'<{NS}displayNameProvisional> true }}')
upsert(s, C, "c.doe@example.com", "")
check("an address replaces it (tier 1 over tier 0)", names(s, C) == ["c.doe@example.com"])
check("and it stays provisional", provisional(s, C))
upsert(s, C, "other@example.com", "")
check("one address does not churn another", names(s, C) == ["c.doe@example.com"])

print("6. a From name that is itself an address")
upsert(s, D, "d@example.com", "d.alias@example.com")
check("is treated as an address, provisional", names(s, D) == ["d@example.com"] and provisional(s, D))

print(f"\n== {PASS} pass / {FAIL} fail ==")
sys.exit(1 if FAIL else 0)
