#!/usr/bin/env python3
"""Tests for PinterestParser.

Regression suite added in v1.0.3 (fix/pinterest-export-shape-v1.0.3).

Verified against real Pinterest Subject Access Request export (Jan 2026):
  - File name:  pinterest.html  (single HTML file, not a directory)
  - Sections gated by h1/h2 id= attributes (bare, unquoted in the real file)
  - can_parse returns True for the real export
  - Real export yields: boards, pins, board_interest aggregates,
    search queries, inferred interests, followees

The SYNTHETIC_HTML fixture below replicates the minimal structural shape of the
real export (section header IDs, data patterns) using wholly invented data so
this file contains zero personal information.

Test cases:
  1.  can_parse() returns True for pinterest.html
  2.  can_parse() returns True for a path containing the word "pinterest"
  3.  can_parse() returns False for non-.html extensions
  4.  can_parse() returns False for .html files without "pinterest" in the name
  5.  can_parse() is case-insensitive
  6.  parse() yields correct pin count from synthetic fixture
  7.  parse() populates pin title and board_name fields
  8.  parse() produces board_interest aggregates only for boards with 3+ pins
  9.  parse() yields search queries from synthetic fixture
  10. parse() yields followees from synthetic fixture
  11. parse() yields inferred interests from synthetic fixture
  12. parse() sets source="pinterest" on all records
  13. parse() respects default_compartment parameter
  14. parse() returns empty list for an HTML file with no Pinterest sections
  15. Real dump: export file is a .html file
  16. Real dump: can_parse() returns True for the real export path
  17. Real dump: all five target section ids present in the real export
  18. Real dump: parse() yields >=700 pins
  19. Real dump: total record count in expected range
"""

import asyncio
import sys
import tempfile
from pathlib import Path

# Make the vendor tree importable without an installed package.
_REPO = Path(__file__).resolve().parent.parent
_INGEST_SRC_PARENT = _REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
sys.path.insert(0, str(_INGEST_SRC_PARENT))

from src.parsers.pinterest import PinterestParser  # noqa: E402


def fail(msg: str) -> None:
    import traceback

    traceback.print_exc()
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Minimal synthetic Pinterest HTML that mirrors the real export's structure.
# IDs are the ones Pinterest's SAR generator uses (verified against Jan 2026
# export): cq8g8=Boards, 0o3mz=Pins, hmz0r=Search history, kp0yp=Interests,
# fmv4l=Followees.  All names/URLs/content are invented.
# ---------------------------------------------------------------------------
_SYNTHETIC_HTML = (
    "<html><head><meta charset=\"utf-8\"/></head><body>"
    "<div id=\"contents\">"
    "<h1 id=anvml>User profile information</h1>"
    "<h2 id=kp0yp>Inferences made about your interests</h2>"
    "Cooking<br/>Architecture<br/>Vintage Cars<br/>"
    "<h1 id=cq8g8>Boards</h1>"
    "<a href=\"https://www.pinterest.com/testuser/home-ideas/\">Home Ideas</a>"
    " Category: home_decor"
    "<a href=\"https://www.pinterest.com/testuser/food-recipes/\">Food Recipes</a>"
    " Category: food_drink"
    "<h1 id=0o3mz>Pins</h1>"
    "<a href=\"https://www.pinterest.com/pin/111111111111111111/\">Pin link</a>"
    "Title: Rustic wooden dining table, Board Name: Home Ideas, Created at: 2023/06/15 09:30:00"
    "<a href=\"https://www.pinterest.com/pin/222222222222222222/\">Pin link</a>"
    "Title: Classic spaghetti carbonara, Board Name: Food Recipes, Created at: 2023/06/16 10:00:00"
    "<a href=\"https://www.pinterest.com/pin/333333333333333333/\">Pin link</a>"
    "Title: Minimalist kitchen shelves, Board Name: Home Ideas, Created at: 2023/06/17 11:00:00"
    "<a href=\"https://www.pinterest.com/pin/444444444444444444/\">Pin link</a>"
    "Title: Homemade sourdough bread, Board Name: Food Recipes, Created at: 2023/06/18 12:00:00"
    "<a href=\"https://www.pinterest.com/pin/555555555555555555/\">Pin link</a>"
    "Title: Industrial loft bedroom, Board Name: Home Ideas, Created at: 2023/06/19 13:00:00"
    "<h1 id=fmv4l>Followees</h1>"
    "<a href=\"https://www.pinterest.com/somedesigner/\">somedesigner</a>"
    "<a href=\"https://www.pinterest.com/foodblogger123/\">foodblogger123</a>"
    "<h1 id=hmz0r>Search history</h1>"
    "Query type: PIN<br/>"
    "Query: mid century modern furniture<br/>"
    "Time(s) of search: 2023/05/10 08:00:00<br/><br/>"
    "Query type: PIN<br/>"
    "Query: pasta recipes<br/>"
    "Time(s) of search: 2023/05/11 09:00:00<br/>"
    "</div></body></html>"
)

_REAL_EXPORT_PATH = Path(
    "/Users/andy/Documents/Projects/CM019 - Personal World Graph"
    "/03 - Social Media archives/1 Jan 2026/10 - Pinterest/pinterest.html"
)

_EXPECTED_SECTION_IDS = {
    "cq8g8",   # Boards
    "0o3mz",   # Pins
    "hmz0r",   # Search history
    "kp0yp",   # Inferences made about your interests
    "fmv4l",   # Followees
}


def _write_html(content: str, filename: str = "pinterest.html") -> Path:
    tmp_dir = tempfile.mkdtemp()
    path = Path(tmp_dir) / filename
    path.write_text(content, encoding="utf-8")
    return path


def _parse_sync(path: Path, **kwargs) -> list:
    parser = PinterestParser()

    async def _collect():
        return [p async for p in parser.parse(path, **kwargs)]

    return asyncio.run(_collect())


# ---------------------------------------------------------------------------
# can_parse tests (1-5)
# ---------------------------------------------------------------------------


def test_can_parse_accepts_pinterest_html() -> None:
    parser = PinterestParser()
    if not parser.can_parse(Path("pinterest.html")):
        fail("can_parse returned False for 'pinterest.html'")
    print("PASS: test_can_parse_accepts_pinterest_html")


def test_can_parse_accepts_path_with_pinterest_in_name() -> None:
    parser = PinterestParser()
    if not parser.can_parse(Path("/some/dir/my_pinterest_export.html")):
        fail("can_parse returned False for path containing 'pinterest'")
    print("PASS: test_can_parse_accepts_path_with_pinterest_in_name")


def test_can_parse_rejects_non_html_extension() -> None:
    parser = PinterestParser()
    for name in ("pinterest.json", "pinterest.csv", "pinterest.xml"):
        if parser.can_parse(Path(name)):
            fail(f"can_parse returned True for non-.html file: {name}")
    print("PASS: test_can_parse_rejects_non_html_extension")


def test_can_parse_rejects_html_without_pinterest_in_name() -> None:
    parser = PinterestParser()
    for name in ("ebay_data.html", "amazon_order_history.html", "export.html", "profile.html"):
        if parser.can_parse(Path(name)):
            fail(f"can_parse returned True for non-Pinterest HTML file: {name}")
    print("PASS: test_can_parse_rejects_html_without_pinterest_in_name")


def test_can_parse_case_insensitive() -> None:
    parser = PinterestParser()
    for name in ("Pinterest_Export.html", "PINTEREST.HTML"):
        if not parser.can_parse(Path(name)):
            fail(f"can_parse returned False for mixed-case name: {name}")
    print("PASS: test_can_parse_case_insensitive")


# ---------------------------------------------------------------------------
# Synthetic fixture parse tests (6-14)
# ---------------------------------------------------------------------------


def test_parse_yields_pins() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    pins = [p for p in prefs if p.extra.get("type") == "pin"]
    if len(pins) != 5:
        fail(f"Expected 5 pins, got {len(pins)}")
    print("PASS: test_parse_yields_pins")


def test_parse_pin_fields() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    pins = [p for p in prefs if p.extra.get("type") == "pin"]
    titles = {p.subject for p in pins}
    for expected in ("Rustic wooden dining table", "Classic spaghetti carbonara"):
        if expected not in titles:
            fail(f"Expected pin title '{expected}' not found in {titles!r}")
    print("PASS: test_parse_pin_fields")


def test_parse_pin_has_board_name() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    pins = [p for p in prefs if p.extra.get("type") == "pin"]
    home_pins = [p for p in pins if p.extra.get("board_name") == "Home Ideas"]
    if len(home_pins) != 3:
        fail(f"Expected 3 pins in 'Home Ideas', got {len(home_pins)}")
    print("PASS: test_parse_pin_has_board_name")


def test_parse_board_interest_aggregates() -> None:
    """Home Ideas has 3 pins -> aggregates; Food Recipes has 2 -> does not."""
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    aggs = [p for p in prefs if p.extra.get("type") == "board_interest"]
    board_names = {p.extra["board_name"] for p in aggs}
    if "Home Ideas" not in board_names:
        fail(f"Expected 'Home Ideas' in board_interest aggregates, got {board_names!r}")
    if "Food Recipes" in board_names:
        fail("Expected 'Food Recipes' NOT in board_interest aggregates (only 2 pins)")
    print("PASS: test_parse_board_interest_aggregates")


def test_parse_yields_search_queries() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    searches = [p for p in prefs if p.extra.get("type") == "search"]
    if len(searches) != 2:
        fail(f"Expected 2 search records, got {len(searches)}")
    queries = {p.extra["query"] for p in searches}
    for expected in ("mid century modern furniture", "pasta recipes"):
        if expected not in queries:
            fail(f"Expected query '{expected}' not found in {queries!r}")
    print("PASS: test_parse_yields_search_queries")


def test_parse_yields_followees() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    followees = [p for p in prefs if p.extra.get("type") == "followee"]
    if len(followees) != 2:
        fail(f"Expected 2 followees, got {len(followees)}")
    usernames = {p.extra["username"] for p in followees}
    for expected in ("somedesigner", "foodblogger123"):
        if expected not in usernames:
            fail(f"Expected followee '{expected}' not found in {usernames!r}")
    print("PASS: test_parse_yields_followees")


def test_parse_yields_inferred_interests() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    interests = [p for p in prefs if p.extra.get("type") == "inferred_interest"]
    if len(interests) < 1:
        fail(f"Expected at least 1 inferred interest, got {len(interests)}")
    print("PASS: test_parse_yields_inferred_interests")


def test_parse_source_name() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    bad = [p for p in prefs if p.source != "pinterest"]
    if bad:
        fail(f"Some records have source != 'pinterest': {[p.source for p in bad]}")
    print("PASS: test_parse_source_name")


def test_parse_default_compartment() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path)
    bad = [p for p in prefs if p.compartment_level != 2]
    if bad:
        fail(f"Some records have compartment_level != 2 under default: {[p.compartment_level for p in bad]}")
    print("PASS: test_parse_default_compartment")


def test_parse_custom_compartment() -> None:
    path = _write_html(_SYNTHETIC_HTML)
    prefs = _parse_sync(path, default_compartment=3)
    bad = [p for p in prefs if p.compartment_level != 3]
    if bad:
        fail(f"Some records have compartment_level != 3 under custom=3: {[p.compartment_level for p in bad]}")
    print("PASS: test_parse_custom_compartment")


def test_parse_empty_sections() -> None:
    path = _write_html("<html><body><h1>Nothing here</h1></body></html>")
    prefs = _parse_sync(path)
    if prefs:
        fail(f"Expected 0 records for empty HTML, got {len(prefs)}")
    print("PASS: test_parse_empty_sections")


# ---------------------------------------------------------------------------
# Real-export structural shape regression tests (15-19)
# ---------------------------------------------------------------------------


def test_real_dump_export_is_html_file() -> None:
    if not _REAL_EXPORT_PATH.exists():
        print("SKIP: real Pinterest export not found -- fixture-only environment")
        return
    if not _REAL_EXPORT_PATH.is_file():
        fail(f"Expected a file at {_REAL_EXPORT_PATH}, got directory or missing")
    if _REAL_EXPORT_PATH.suffix.lower() != ".html":
        fail(f"Expected .html extension, got {_REAL_EXPORT_PATH.suffix!r}")
    print("PASS: test_real_dump_export_is_html_file")


def test_real_dump_can_parse() -> None:
    if not _REAL_EXPORT_PATH.exists():
        print("SKIP: real Pinterest export not found -- fixture-only environment")
        return
    parser = PinterestParser()
    if not parser.can_parse(_REAL_EXPORT_PATH):
        fail(f"can_parse returned False for real export at {_REAL_EXPORT_PATH}")
    print("PASS: test_real_dump_can_parse")


def test_real_dump_section_ids_present() -> None:
    """All five target section ids must be referenced in the export.

    The real Pinterest SAR export is a single long HTML line (~5.7 MB).
    The table-of-contents navigation block appears in the first 30 KB and
    contains href="#<id>" anchor links to every section.  All five parser
    target sections are present in the TOC and (at various byte offsets
    across the full file) as id=<id> attributes on h1/h2 elements.
    """
    if not _REAL_EXPORT_PATH.exists():
        print("SKIP: real Pinterest export not found -- fixture-only environment")
        return
    with _REAL_EXPORT_PATH.open(encoding="utf-8") as fh:
        toc_block = fh.read(65536)  # 64 KB -- covers the TOC nav block

    missing = {
        sid
        for sid in _EXPECTED_SECTION_IDS
        if (
            f"#{sid}" not in toc_block
            and f"id={sid}" not in toc_block
            and f'id="{sid}"' not in toc_block
        )
    }
    if missing:
        fail(
            f"Pinterest export is missing expected section id(s): {missing!r}\n"
            "The export format may have changed -- review PinterestParser before next ingest."
        )
    print("PASS: test_real_dump_section_ids_present")


def test_real_dump_yields_pins() -> None:
    """Regression: the real export must yield at least 700 pins.

    Based on Jan 2026 export: 767 pin records confirmed.  The threshold
    is set conservatively to 700 so minor format tweaks do not trip it,
    but a parser regression (0 pins) breaks immediately.
    """
    if not _REAL_EXPORT_PATH.exists():
        print("SKIP: real Pinterest export not found -- fixture-only environment")
        return
    parser = PinterestParser()

    async def _count() -> int:
        count = 0
        async for pref in parser.parse(_REAL_EXPORT_PATH):
            if pref.extra.get("type") == "pin":
                count += 1
        return count

    pin_count = asyncio.run(_count())
    if pin_count < 700:
        fail(
            f"Expected >=700 pins from real export, got {pin_count}. "
            "Parser may have broken on a format change."
        )
    print(f"PASS: test_real_dump_yields_pins (got {pin_count} pins)")


def test_real_dump_total_record_count() -> None:
    """Total record count must stay in a sane range around the Jan 2026 baseline (999).

    Threshold: >=900 (allows for future pins being removed/deduped at
    source) and <=2000 (a runaway parser would explode this).
    """
    if not _REAL_EXPORT_PATH.exists():
        print("SKIP: real Pinterest export not found -- fixture-only environment")
        return
    parser = PinterestParser()

    async def _count() -> int:
        count = 0
        async for _ in parser.parse(_REAL_EXPORT_PATH):
            count += 1
        return count

    total = asyncio.run(_count())
    if not 900 <= total <= 2000:
        fail(
            f"Real export total record count {total} is outside expected range [900, 2000]. "
            "Inspect parser output -- structure may have changed."
        )
    print(f"PASS: test_real_dump_total_record_count (got {total} records)")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    test_can_parse_accepts_pinterest_html()
    test_can_parse_accepts_path_with_pinterest_in_name()
    test_can_parse_rejects_non_html_extension()
    test_can_parse_rejects_html_without_pinterest_in_name()
    test_can_parse_case_insensitive()
    test_parse_yields_pins()
    test_parse_pin_fields()
    test_parse_pin_has_board_name()
    test_parse_board_interest_aggregates()
    test_parse_yields_search_queries()
    test_parse_yields_followees()
    test_parse_yields_inferred_interests()
    test_parse_source_name()
    test_parse_default_compartment()
    test_parse_custom_compartment()
    test_parse_empty_sections()
    test_real_dump_export_is_html_file()
    test_real_dump_can_parse()
    test_real_dump_section_ids_present()
    test_real_dump_yields_pins()
    test_real_dump_total_record_count()
    print("\nALL PINTEREST PARSER TESTS PASSED")


if __name__ == "__main__":
    main()
