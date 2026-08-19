#!/usr/bin/env python3
"""#657 pref-noise: drop Facebook reaction-owner names + per-source priority cap.

The GDPR social-archive ingest can land tens of thousands of low-signal rows
from a single export: a person's name captured because you once reacted to their
Facebook post (the legacy "social" category), or an enormous "saved" tail. Left
unchecked these balloon the preference count and crowd out genuine taste signals
from every other source.

Two policies, both verified here against SYNTHETIC fixtures (no real archive
data, PRODUCTISATION_CHECKLIST.md Rule 0):

  1. Drop -- reaction-owner rows (category == "social") never reach the graph as
     preferences. Proven both via the filter predicate AND end-to-end through the
     real MetaParser parsing a synthetic legacy-reaction export.
  2. Per-source priority cap -- when a source exceeds MAX_PREFS_PER_SOURCE, the
     high-signal head (pages/follows/curated content) survives and the low-value
     tail (saved/media) is trimmed first. Every trimmed row is logged: no silent
     truncation.

No live Qdrant/Oxigraph/Ollama needed -- this exercises the filter directly.
"""

import asyncio
import json
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST_SRC_PARENT = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
sys.path.insert(0, str(INGEST_SRC_PARENT))

from src.filters import PreferenceFilter  # noqa: E402
from src.parsers.base import ParsedPreference  # noqa: E402
from src.parsers.meta import MetaParser  # noqa: E402


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def _pref(subject: str, category: str, source: str = "facebook", strength: float = 0.25,
          frequency: int = 1) -> ParsedPreference:
    return ParsedPreference(
        subject=subject,
        preference_type="Like",
        strength=strength,
        source=source,
        category=category,
        extra={"frequency": frequency},
    )


def test_drop_reaction_owner_category() -> None:
    """category == 'social' is dropped; high-signal categories are not."""
    f = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)

    reaction_owner = _pref("Jane Smith", "social")
    if not f.is_dropped_category(reaction_owner):
        fail("reaction-owner row (category='social') was NOT flagged as dropped")
    if f.should_include(reaction_owner):
        fail("should_include let a category='social' reaction-owner row through")
    if f.stats["filtered_dropped_category"] != 1:
        fail(f"filtered_dropped_category not counted: {f.stats['filtered_dropped_category']}")

    # Case-insensitive / whitespace robustness.
    if not f.is_dropped_category(_pref("Bob", " Social ")):
        fail("drop check is not case/whitespace insensitive")

    # High-signal categories must survive the drop gate.
    for keep in ("page", "facebook_content", "instagram_creator", "music", "book", "saved"):
        if f.is_dropped_category(_pref("Keep Me", keep)):
            fail(f"category '{keep}' was wrongly flagged as a dropped category")

    print("PASS: reaction-owner 'social' rows dropped; high-signal categories kept")


def test_per_source_priority_cap() -> None:
    """A source over the cap keeps the high-signal head, trims the low tail, logs it."""
    f = PreferenceFilter(enable_dedup=True, aggregate_frequency=True)

    cap = PreferenceFilter.MAX_PREFS_PER_SOURCE  # 5000
    n_pages = 4000           # high signal (rank 10)
    n_saved = 3000           # low-value tail (rank 80)
    prefs = (
        [_pref(f"Page {i}", "page", strength=0.25) for i in range(n_pages)]
        + [_pref(f"Saved {i}", "saved", strength=0.35) for i in range(n_saved)]
    )
    # A second, small source must be untouched by the cap.
    prefs += [_pref(f"Song {i}", "music", source="spotify") for i in range(100)]

    kept, capped_log = f.cap_by_source(prefs)

    by_source = {}
    for p in kept:
        by_source.setdefault(p.source, []).append(p)

    fb = by_source.get("facebook", [])
    if len(fb) != cap:
        fail(f"facebook kept {len(fb)} rows; expected the cap {cap}")

    fb_pages = [p for p in fb if p.category == "page"]
    fb_saved = [p for p in fb if p.category == "saved"]
    if len(fb_pages) != n_pages:
        fail(f"all {n_pages} high-signal 'page' rows should survive; kept {len(fb_pages)}")
    if len(fb_saved) != cap - n_pages:
        fail(f"expected {cap - n_pages} 'saved' survivors; kept {len(fb_saved)}")

    expected_trim = (n_pages + n_saved) - cap  # 2000
    if len(capped_log) != expected_trim:
        fail(f"capped_log has {len(capped_log)} rows; expected {expected_trim}")
    if any(row["category"] != "saved" for row in capped_log):
        fail("the trimmed tail must be entirely 'saved' rows (lowest priority)")
    if f.stats["capped_by_source"] != expected_trim:
        fail(f"capped_by_source stat {f.stats['capped_by_source']} != {expected_trim}")

    # The under-cap source passes through whole.
    if len(by_source.get("spotify", [])) != 100:
        fail("under-cap source 'spotify' was wrongly trimmed")

    print(f"PASS: per-source cap kept high-signal head, trimmed {expected_trim} 'saved' "
          f"rows, logged every one")


def test_source_under_cap_untouched() -> None:
    """A source below the cap returns identical rows, nothing logged."""
    f = PreferenceFilter()
    prefs = [_pref(f"Page {i}", "page") for i in range(10)]
    kept, capped_log = f.cap_by_source(prefs)
    if len(kept) != 10 or capped_log:
        fail(f"under-cap source altered: kept={len(kept)} capped={len(capped_log)}")
    print("PASS: source under the cap is passed through untouched")


def test_meta_parser_emits_droppable_social_category() -> None:
    """End-to-end: real MetaParser on a synthetic legacy reaction export yields a
    category='social' row, which the filter then drops."""
    # Synthetic legacy Facebook reaction export (pre-2026 shape): a reaction to
    # a named person's post. The parser maps this to category='social'.
    synthetic = [
        {
            "title": "You reacted to Pat Carter's post",
            "timestamp": 1700000000,
            "data": [{"reaction": {"reaction": "LIKE"}}],
        }
    ]

    async def _run():
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "likes_and_reactions.json"
            p.write_text(json.dumps(synthetic), encoding="utf-8")
            parser = MetaParser()
            out = []
            async for pref in parser.parse(p, default_compartment=2):
                out.append(pref)
            return out

    parsed = asyncio.run(_run())
    social = [p for p in parsed if (p.category or "").lower() == "social"]
    if not social:
        fail("MetaParser did not emit a category='social' row for a legacy reaction "
             "(fixture or parser contract changed)")

    f = PreferenceFilter()
    if any(f.should_include(p) for p in social):
        fail("filter let a real MetaParser-emitted 'social' reaction-owner row through")
    print("PASS: real MetaParser legacy reaction -> category='social' -> dropped by filter")


def main() -> None:
    test_drop_reaction_owner_category()
    test_per_source_priority_cap()
    test_source_under_cap_untouched()
    test_meta_parser_emits_droppable_social_category()
    print("\nALL PREF-NOISE SOURCE-CAP TESTS PASSED")


if __name__ == "__main__":
    main()
