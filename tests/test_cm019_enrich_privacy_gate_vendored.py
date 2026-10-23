#!/usr/bin/env python3
"""The vendored enrich tree never sends a private item or a minor online.

Upstream: personal-world-graph fix/enrich-privacy-gate (privacy_gate.py is
byte-identical; the enricher.py changed lines are the same multiset).

Consent ACCEPTED in every arm except the last, and every item carries
extra.category_inferred=False so eligibility.py lets it through: whatever
stops an item here is the privacy gate, nothing else.

  arm 1  L3 (string, legacy 3, named node) -> 0 outbound requests
  arm 2  a minor (extra.about_minor) at a publishable level -> 0
  arm 3  no level at all -> 0
  arm 4  L0, L1, legacy 0/1/5, unknown, and a disagreeing pair -> 0
  arm 5  CONTROL: publishable (legacy 2, string L2) -> exactly 1, so the
         counter is live and the gate does not block publishable data
  arm 6  no consent, publishable -> 0 (the consent gate still holds)
  arm 7  enrich_all from a Qdrant scroll: the level in the stored payload
         reaches the gate; 4 points in, 1 request out
  arm 8  enrich_preference called directly is gated too
  arm 9  the log line carries counts, never the subject

Fake HTTP client: every httpx.AsyncClient gets a MockTransport; requests to
the local Qdrant/Oxigraph are answered, anything else is counted as external.
Synthetic cast only (Sam Doe, Jane Smith).

Exit: 0 pass, 1 real failure, 2 cannot-run.
"""

import asyncio
import logging
import os
import sys
import tempfile
from pathlib import Path
from urllib.parse import urlparse

REPO = Path(__file__).resolve().parent.parent
ENRICH = REPO / "vendor" / "cm019_preferences" / "services" / "enrich"
KEY = "OSTLER_CONSENT_ENRICHMENT_DECISION"

for var in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
    os.environ.pop(var, None)
os.environ["NO_PROXY"] = "127.0.0.1,localhost"
os.environ.pop(KEY, None)
TMP = Path(tempfile.mkdtemp(prefix="cm019-privacy-"))
os.environ["OSTLER_DIR"] = str(TMP / "ostler")
os.environ["HOME"] = str(TMP / "home")

sys.path.insert(0, str(ENRICH))
try:
    import httpx
    from src import enricher as enricher_module
    from src.config import settings
except Exception as exc:  # noqa: BLE001
    print(f"CANNOT RUN: vendored enrich tree does not import: {exc!r}", file=sys.stderr)
    sys.exit(2)
try:
    from src.privacy_gate import outbound_refusal
except ImportError as exc:
    print(f"FAIL  the vendored tree has no src/privacy_gate.py: {exc!r}", file=sys.stderr)
    sys.exit(1)

EnrichmentService = enricher_module.EnrichmentService
EnrichmentStats = enricher_module.EnrichmentStats
SUBJECT = "notes for Jane Smith from Sam Doe"
FAILS = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{(' -- ' + detail) if detail and not ok else ''}")
    if not ok:
        FAILS.append(name)


def set_consent(value):
    cfg = Path(os.environ["OSTLER_DIR"]) / "config"
    cfg.mkdir(parents=True, exist_ok=True)
    env = cfg / ".env"
    if value is None:
        os.environ.pop(KEY, None)
        env.unlink(missing_ok=True)
    else:
        os.environ[KEY] = value
        env.write_text(f"{KEY}={value}\n", encoding="utf-8")


EXTERNAL = []
SCROLL_POINTS = []
LOCAL = {(urlparse(u).hostname, urlparse(u).port) for u in (settings.oxigraph_url, settings.qdrant_url)}


def handler(request):
    if (request.url.host, request.url.port) in LOCAL:
        if request.url.path.endswith("/points/scroll"):
            return httpx.Response(200, json={"result": {"points": SCROLL_POINTS, "next_page_offset": None}})
        if request.url.path.endswith("/query"):
            return httpx.Response(200, json={"boolean": False})
        return httpx.Response(204)
    EXTERNAL.append(request.url.host)
    return httpx.Response(200, json={"docs": [], "numFound": 0})


_Real = httpx.AsyncClient


class RecordingClient(_Real):
    def __init__(self, *args, **kwargs):
        kwargs["transport"] = httpx.MockTransport(handler)
        super().__init__(*args, **kwargs)


httpx.AsyncClient = RecordingClient


async def _no_sleep(_):
    return None


enricher_module.asyncio.sleep = _no_sleep


def pref(pid, extra=None, **fields):
    e = {"category_inferred": False}
    e.update(extra or {})
    p = {"id": pid, "category": "book", "subject": SUBJECT, "extra": e}
    p.update(fields)
    return p


async def run_batch(p):
    EXTERNAL.clear()
    service = EnrichmentService()
    stats = EnrichmentStats()
    try:
        await service.enrich_batch([p], stats)
    finally:
        await service.close()
    return stats


async def main():
    set_consent("accepted")

    for label, fields in (("string L3", {"privacy_level": "L3"}),
                          ("legacy 3", {"compartment_level": 3}),
                          ("named L3Community", {"compartment_level": "pwg:L3Community"})):
        stats = await run_batch(pref("p", **fields))
        check(f"arm 1  {label}: 0 outbound", EXTERNAL == [] and stats.skipped_private == 1,
              f"external={EXTERNAL} skipped_private={stats.skipped_private}")

    stats = await run_batch(pref("p", extra={"about_minor": True}, compartment_level=2))
    check("arm 2  minor: 0 outbound", EXTERNAL == [] and stats.by_privacy_reason == {"minor": 1},
          f"external={EXTERNAL} reasons={stats.by_privacy_reason}")

    stats = await run_batch(pref("p"))
    check("arm 3  missing level: 0 outbound",
          EXTERNAL == [] and stats.by_privacy_reason == {"level_unknown": 1},
          f"external={EXTERNAL} reasons={stats.by_privacy_reason}")

    for fields, reason in (({"privacy_level": "L0"}, "level_L0"),
                           ({"privacy_level": "L1"}, "level_L1"),
                           ({"compartment_level": 0}, "level_legacy_0"),
                           ({"compartment_level": 1}, "level_legacy_1"),
                           ({"compartment_level": 5}, "level_legacy_5"),
                           ({"privacy_level": "nonsense"}, "level_unknown"),
                           ({"privacy_level": "L2", "compartment_level": 3}, "level_legacy_3")):
        stats = await run_batch(pref("p", **fields))
        check(f"arm 4  {fields}: 0 outbound, reason {reason}",
              EXTERNAL == [] and stats.by_privacy_reason == {reason: 1},
              f"external={EXTERNAL} reasons={stats.by_privacy_reason}")

    for fields in ({"compartment_level": 2}, {"privacy_level": "L2"}):
        stats = await run_batch(pref("p", **fields))
        check(f"arm 5  CONTROL {fields} with consent: exactly 1 outbound",
              len(EXTERNAL) == 1 and stats.skipped_private == 0,
              f"external={EXTERNAL} skipped_private={stats.skipped_private}")

    for value in (None, "declined"):
        set_consent(value)
        await run_batch(pref("p", compartment_level=2))
        check(f"arm 6  consent {value!r}, publishable: 0 outbound", EXTERNAL == [], f"external={EXTERNAL}")
    set_consent("accepted")

    EXTERNAL.clear()
    base = {"category": "book", "subject": SUBJECT, "user_id": "u"}
    SCROLL_POINTS[:] = [
        {"id": "a", "payload": {**base, "compartment_level": 3, "extra": {"category_inferred": False}}},
        {"id": "b", "payload": {**base, "compartment_level": 2,
                                "extra": {"category_inferred": False, "about_minor": True}}},
        {"id": "c", "payload": {**base, "extra": {"category_inferred": False}}},
        {"id": "d", "payload": {**base, "compartment_level": 2, "extra": {"category_inferred": False}}},
    ]
    service = EnrichmentService()
    try:
        stats = await service.enrich_all(category="book", limit=10, batch_size=10)
    finally:
        await service.close()
    check("arm 7  enrich_all from the store: 4 in, 1 out, 3 withheld by reason",
          len(EXTERNAL) == 1 and stats.by_privacy_reason
          == {"level_legacy_3": 1, "minor": 1, "level_unknown": 1},
          f"external={EXTERNAL} reasons={stats.by_privacy_reason}")

    EXTERNAL.clear()
    service = EnrichmentService()
    try:
        r1 = await service.enrich_preference(pref("p", privacy_level="L3"))
        r2 = await service.enrich_preference(pref("p", extra={"about_minor": True}, compartment_level=2))
        gated = (r1 is None and r2 is None and EXTERNAL == []
                 and service.privacy_refusals == {"level_L3": 1, "minor": 1})
        await service.enrich_preference(pref("p", compartment_level=2))
        check("arm 8  enrich_preference direct: gated, control reaches the wire",
              gated and len(EXTERNAL) == 1, f"external={EXTERNAL} refusals={service.privacy_refusals}")
    finally:
        await service.close()

    records = []

    class Grab(logging.Handler):
        def emit(self, record):
            records.append(record.getMessage())

    h = Grab(level=logging.DEBUG)
    root = logging.getLogger()
    root.addHandler(h)
    old = root.level
    root.setLevel(logging.DEBUG)
    try:
        await run_batch(pref("p", privacy_level="L3"))
    finally:
        root.removeHandler(h)
        root.setLevel(old)
    text = "\n".join(records)
    check("arm 9  log carries the count, never the subject",
          "withheld 1 item" in text and all(n not in text for n in ("Sam Doe", "Jane Smith")),
          "log=" + repr(text[:300]))

    # The gate's verdict alone, so a reader can see the ladder in one place.
    check("ladder: legacy 4 and 6 are publishable",
          outbound_refusal(pref("p", compartment_level=4)) is None
          and outbound_refusal(pref("p", compartment_level=6)) is None)


asyncio.run(main())
print(f"\n{'FAIL' if FAILS else 'PASS'}: {len(FAILS)} failure(s)")
sys.exit(1 if FAILS else 0)
