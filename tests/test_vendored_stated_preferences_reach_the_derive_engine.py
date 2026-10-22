#!/usr/bin/env python3
"""What the owner SAYS in conversations reaches the shipped derive engine.

Drives the VENDORED tree (vendor/cm019_preferences/services/enrich/src/derive)
the way the Hub's derive_runner does: build_readers(gateway) from the shipped
registry, DerivationEngine, Aggregator. The store is an rdflib dataset loaded
with facts in the exact triple shape CM048's _fact_to_triples writes, answering
the reader's real SPARQL. Synthetic text only.

  arm 1  "hates coffee" in three conversations -> food.drink Coffee, negative,
         with more confidence than the same statement once.
  arm 2  "not really a fan of Cantonese, love Sichuan" -> food.cuisine
         Cantonese negative, Sichuan positive.
  arm 3  a friend saying they love jazz is NOT an owner preference.
  arm 4  the derived node carries no message text; its because line is fixed.
  arm 5  the runner's user label ("ostler") differs from the CM048 user name on
         the facts and the facts are still read (a userId filter reads nothing).
  arm 6  MUTANT: with the stated row dropped from a copy of readers.yaml the
         feature disappears, so arms 1-2 cannot pass on some other row.
  arm 7  the shipped derive_runner builds its readers through build_readers, so
         the stated reader is among the readers it runs.

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""
from __future__ import annotations

import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TREE = REPO / "vendor" / "cm019_preferences"
SRC = TREE / "services" / "enrich" / "src"
DERIVE = SRC / "derive"
# The subject under test being absent is a FAIL (the feature is not shipped),
# not a CANNOT-RUN: the instrument is the rest of the tree, which must be there.
for p in (DERIVE / "stated.py", DERIVE / "stated_vocab.yaml"):
    if not p.is_file():
        print(f"FAIL: {p.relative_to(REPO)} is not in the vendored tree")
        sys.exit(1)
for p in (DERIVE / "readers.yaml", TREE / "services" / "common" / "strength.py"):
    if not p.is_file():
        print(f"CANNOT-RUN: {p.relative_to(REPO)} is missing")
        sys.exit(2)
try:
    import rdflib
    import yaml
except ImportError as exc:
    print(f"CANNOT-RUN: {exc}. pip install pyyaml rdflib")
    sys.exit(2)

sys.path.insert(0, str(TREE / "services" / "common"))
sys.path.insert(0, str(SRC))
from derive.config import READERS_YAML, build_readers, load_dimensions  # noqa: E402
from derive.engine import Aggregator, DerivationEngine  # noqa: E402
from derive.stated import STATED_BECAUSE, StatedConversationReader  # noqa: E402

NOW = datetime(2026, 10, 22, tzinfo=timezone.utc)
PASS = FAIL = 0


def check(cond, msg):
    global PASS, FAIL
    PASS, FAIL = (PASS + 1, FAIL) if cond else (PASS, FAIL + 1)
    print(("  PASS " if cond else "  FAIL ") + msg)


class FactStore:
    def __init__(self):
        self.ds = rdflib.Dataset()
        self.n = 0
        self.texts = []

    def fact(self, text, about="user/Owner", user="Owner", type="preference"):
        self.n += 1
        self.texts.append(text)
        lit = text.replace("\\", "\\\\").replace('"', '\\"')
        ttl = (
            f'<urn:ostler:fact/f{self.n}> a <urn:ostler:Fact> ;\n'
            f'  <urn:ostler:fromConversation> <urn:ostler:conversation/c{self.n}> ;\n'
            f'  <urn:ostler:about> <urn:ostler:{about}> ; <urn:ostler:userId> "{user}" ;\n'
            f'  <urn:ostler:type> "{type}" ; <urn:ostler:domain> "food" ;\n'
            f'  <urn:ostler:privacyLevel> "L1" ; <urn:ostler:signalStrength> "strong" ;\n'
            f'  <urn:ostler:provenanceHeader> "[pwg:src=imessage id=x date=2026-09-01]" ;\n'
            f'  <urn:ostler:text> "{lit}" .\n'
        )
        self.ds.graph(rdflib.URIRef("urn:ostler:user/Owner")).parse(data=ttl, format="turtle")

    def sparql(self, query):
        return [{str(k): {"value": str(v)} for k, v in r.asdict().items()}
                for r in self.ds.query(query)]

    def scroll(self, categories, fields):
        return []


def run(store, readers_path=READERS_YAML, user="ostler"):
    readers = build_readers(store, path=readers_path)
    res = DerivationEngine(readers=readers, aggregator=Aggregator(load_dimensions())).run_result(user, now=NOW)
    return {(n.dimension, n.subject): n for n in res.nodes}, res


def main():
    once, three = FactStore(), FactStore()
    once.fact("Owner hates coffee.")
    for t in ("Owner hates coffee.", "Owner can't stand coffee.", "Owner dislikes coffee."):
        three.fact(t)
    n1, r1 = run(once)
    n3, _ = run(three)
    c1, c3 = n1.get(("food.drink", "Coffee")), n3.get(("food.drink", "Coffee"))
    print("arm 1: coffee x3 vs x1")
    check(r1.ok, "no reader failed")
    check(c1 is not None and c3 is not None, "food.drink Coffee derives")
    check(c3 is not None and c3.preference_strength < 0, "polarity negative")
    check(c1 is not None and c3 is not None and c3.confidence > c1.confidence,
          "three conversations are more confident than one")

    s = FactStore()
    s.fact("Owner is not really a fan of Cantonese food, but loves Sichuan.")
    n, _ = run(s)
    print("arm 2: Cantonese / Sichuan")
    check(n.get(("food.cuisine", "Cantonese")) is not None and n[("food.cuisine", "Cantonese")].preference_strength < 0,
          "Cantonese negative")
    check(n.get(("food.cuisine", "Sichuan")) is not None and n[("food.cuisine", "Sichuan")].preference_strength > 0,
          "Sichuan positive")

    f = FactStore()
    f.fact("Alex loves jazz.", about="other/alex_chen")
    nf, _ = run(f)
    f.fact("Owner loves jazz.")
    nf2, _ = run(f)
    print("arm 3: friend vs owner")
    check(nf == {}, "a friend's jazz is not an owner preference")
    check(("media.music.genre", "Jazz") in nf2, "control: the owner's own jazz derives")

    print("arm 4: no message text")
    t = FactStore()
    t.fact("Owner absolutely hates coffee, it ruins every morning meeting.")
    nt, _ = run(t)
    node = nt.get(("food.drink", "Coffee"))
    check(node is not None, "the node exists to be inspected")
    if node is not None:
        ttl = node.to_turtle()
        check("ruins every morning" not in ttl and t.texts[0] not in ttl, "turtle has no message text")
        check(node.evidence_titles == [STATED_BECAUSE], "because line is the fixed sentence")

    print("arm 5: runner user label differs from the CM048 user name")
    u = FactStore()
    u.fact("Owner loves coffee.", user="SomeConfiguredName")
    nu, _ = run(u, user="ostler")
    check(("food.drink", "Coffee") in nu, "facts are read under user 'ostler'")

    print("arm 6: MUTANT, stated row dropped")
    rows = yaml.safe_load(Path(READERS_YAML).read_text())
    with tempfile.TemporaryDirectory() as d:
        mp = Path(d) / "readers.yaml"
        mp.write_text(yaml.safe_dump([r for r in rows if r["kind"] != "stated_conversation"]))
        nm, _ = run(three, readers_path=mp)
    check(("food.drink", "Coffee") not in nm and n3 != {}, "without the row there is no Coffee node")

    print("arm 7: the shipped runner builds readers through build_readers")
    src = (SRC / "derive_runner.py").read_text()
    check("readers = build_readers(gateway)" in src, "derive_runner calls build_readers(gateway)")
    check(any(isinstance(r, StatedConversationReader) for r in build_readers(FactStore())),
          "that registry includes the stated reader")

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
