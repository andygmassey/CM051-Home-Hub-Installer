#!/usr/bin/env python3
"""An explicit L0 survives the SHIPPED ingest as L0 (vendored cm019_preferences).

Upstream: personal-world-graph fix/ingest-explicit-l0-survives (same five
replacements). compartment_level 0 is L0Personal, the strictest level.
`compartment_level or default` read 0 as "not given" and stored the default 2
(L2 publishable), so an owner-private item became shareable and eligible for
online enrichment. The same idiom sat in parsers/email.py and in the Apple TV
app activity parser.

Drives the real vendored IngestPipeline and CSV parser; the Qdrant payload and
Oxigraph turtle are captured at the two loaders, and the embedder is stubbed.

  arm 1  explicit 0 through ingest_file, ingest_file_with_aggregation and
         ingest_directory: every payload says 0 and the turtle L0Personal
  arm 2  CONTROL: no level given gets settings.default_compartment
  arm 3  CONTROL: explicit 3 stays 3
  arm 4  email parser: caller default 0 wins over the row's own 2
  arm 5  Apple TV activity: default 0 stays 0, None becomes 2

Synthetic cast only. Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
TMP = Path(tempfile.mkdtemp(prefix="cm019-l0-"))
os.environ["HOME"] = str(TMP / "home")
os.environ["OSTLER_MINORS_FILE"] = str(TMP / "no-minors.json")
sys.path.insert(0, str(INGEST))
try:
    from src import pipeline as pipeline_module
    from src.config import settings
    from src.parsers.apple import AppleParser
    from src.parsers.email import EmailParser
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: vendored ingest tree does not import: {exc!r}", file=sys.stderr)
    sys.exit(2)

FAILS = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{(' -- ' + detail) if detail and not ok else ''}")
    if not ok:
        FAILS.append(name)


ROWS = "subject,category\nSam Doe gardening club,interest\nJane Smith pottery,interest\n"


def make_pipe():
    p = pipeline_module.IngestPipeline()
    p.cap_payloads, p.cap_turtle = [], []

    async def upsert_vectors(vectors, payloads, ids=None):
        p.cap_payloads.extend(payloads)
        return True

    async def insert_triples(turtle, graph=None):
        p.cap_turtle.append(turtle)
        return True

    p.qdrant.upsert_vectors = upsert_vectors
    p.oxigraph.insert_triples = insert_triples
    return p


pipeline_module.vectorizer.embed_batch = lambda texts, *a, **k: [[0.0] * 4 for _ in texts]


def csv_file(tag):
    d = TMP / f"in-{tag}"
    d.mkdir()
    f = d / "prefs.csv"
    f.write_text(ROWS, encoding="utf-8")
    return f


async def ingest(entry, level, tag):
    p = make_pipe()
    f = csv_file(tag)
    kw = {} if level is None else {"compartment_level": level}
    if entry == "ingest_file":
        await p.ingest_file(f, "u", **kw)
    elif entry == "ingest_file_with_aggregation":
        await p.ingest_file_with_aggregation(f, "u", **kw)
    else:
        await p.ingest_directory(f.parent, "u", **kw)
    return sorted({pl.get("compartment_level") for pl in p.cap_payloads}), "\n".join(p.cap_turtle), len(p.cap_payloads)


async def main():
    n = 0
    for entry in ("ingest_file", "ingest_file_with_aggregation", "ingest_directory"):
        n += 1
        levels, turtle, count = await ingest(entry, 0, f"{n}a")
        check(f"arm 1  {entry}: explicit 0 stays 0",
              count > 0 and levels == [0] and "pwg:L0Personal" in turtle and "pwg:L2Trusted" not in turtle,
              f"payloads={count} levels={levels}")
        levels, _, count = await ingest(entry, None, f"{n}b")
        check(f"arm 2  {entry}: no level gets the default {settings.default_compartment}",
              count > 0 and levels == [settings.default_compartment], f"levels={levels}")
        levels, _, count = await ingest(entry, 3, f"{n}c")
        check(f"arm 3  {entry}: explicit 3 stays 3", count > 0 and levels == [3], f"levels={levels}")

    ef = TMP / "email_prefs.jsonl"
    ef.write_text(json.dumps({"subject": "Tom Jones newsletter", "category": "interest",
                              "strength": 0.8, "source": "email", "compartment_level": 2,
                              "preference_type": "Like"}) + "\n", encoding="utf-8")

    async def email(default):
        return [p.compartment_level async for p in EmailParser().parse(ef, default_compartment=default)]

    got0, got_none = await email(0), await email(None)
    check("arm 4  email: caller default 0 beats the row's 2; None keeps the row's 2",
          got0 == [0] and got_none == [2], f"0->{got0} None->{got_none}")

    tf = TMP / "TV App Favorites and Activity.json"
    tf.write_text(json.dumps({"events": [{
        "stored_event": {"media_type": "MOVIE", "timestamp": 1768483526049,
                         "statistics": {"max_progress_percentage": 95.0,
                                        "start_play_event_statistics": {"count": 2}}},
        "event_interpretation": {
            "media_description": "Synthetic film (Directed by: [Sam Doe], Released in: [2001])",
            "channel_name": "Synthetic channel"}}]}), encoding="utf-8")

    async def tv(default):
        return [p.compartment_level async for p in AppleParser()._parse_tv_app_activity(tf, default)]

    t0, tn = await tv(0), await tv(None)
    check("arm 5  Apple TV activity: 0 stays 0, None becomes 2",
          bool(t0) and set(t0) == {0} and set(tn) == {2}, f"0->{t0} None->{tn}")


asyncio.run(main())
print(f"\n{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failure(s)")
sys.exit(1 if FAILS else 0)
