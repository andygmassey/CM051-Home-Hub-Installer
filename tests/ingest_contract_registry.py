"""The INGEST CONTRACT registry: every importer declares what it keeps.

WHY THIS FILE EXISTS (Andy, 2026-10-22): "If we don't get this preference work
(ingest > enrich > derivation) right at the start, then the user will NEVER get
their preferences determined." Measured the same day on a walk box: 68,311
Apple Music points carried a song and an album and no artist field, so no
rollup could ever reach them; 4,723 bookmarks carried the IMPORT time as their
event time; three writers stored no owner at all. Each one was invisible
because nothing asked an importer what it KEEPS.

THE CONTRACT. Every source that writes preference evidence declares all six,
and cannot register without doing so (Decl has no defaults):

  entity     the who/what derivation rolls up on (artist, show, author, brand,
             restaurant, domain), as {category: (extra keys, any one of)}.
             A category whose subject IS the entity (a film title) lists none.
  category   the item's own category, set by the parser (not guessed later).
  timestamp  a REAL event time in observed_at, never the import time, because
             decay reads it. Categories listed here are checked.
  owner      whose preference it is: "own_export" (a platform export is the
             account holder's by construction) or "speaker:<extra key>" for a
             message source, where the speaker decides who the preference is.
  privacy    an integer compartment_level on every point.
  item_key   a stable id: parsing the same input twice gives the same ids, so
             enrichment can run once per item and re-imports upsert.

A field a source cannot yet meet is declared as a Gap: a reason, and whether
the RAW export still holds the field (so a parser fix plus re-import recovers
it). Gaps are explicit, counted, and ratcheted: tests/test_ingest_contract.py
fails when a gap is added without editing GAP_BASELINE, and fails when a gap
that a fixture proves is closed is still declared.

UNMEASURED means no points from that source exist on the measured box; it is a
gap in OUR instrument, not a pass.
"""
from __future__ import annotations

import asyncio
import csv
import json
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple, Union


@dataclass(frozen=True)
class Gap:
    reason: str
    raw_has_it: Optional[bool]  # True / False / None (not checked)


Field = Union[str, Gap]


@dataclass(frozen=True)
class Decl:
    """No defaults on purpose: a new importer cannot skip a field."""
    entity: Dict[str, Tuple[str, ...]]
    category: Field
    timestamp: Tuple[str, ...]          # categories whose observed_at is checked
    owner: Field
    privacy: Field
    item_key: Field
    gaps: Dict[str, Gap] = field(default_factory=dict)  # "entity:cat", "timestamp:cat", ...
    fixture: Optional[Callable[[Path], list]] = None


def _all_parsed(parser, files: List[Path]) -> list:
    async def run():
        out = []
        for f in files:
            async for p in parser.parse(f):
                out.append(p)
        return out
    return asyncio.run(run())


# ---------------------------------------------------------------------------
# Synthetic fixtures. Obviously fake labels; no real artist, title or person.
# ---------------------------------------------------------------------------
def _csv(path: Path, header: List[str], rows: List[List[str]]) -> Path:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    return path


def fixture_apple_music(tmp: Path) -> list:
    from services.ingest.src.parsers.apple import AppleParser
    history = _csv(tmp / "Apple Music - Track Play History.csv",
                   ["Track Name", "Last Played Date", "Is User Initiated"],
                   [["Fixture Band - Fixture Song", "1700000000000", "true"]])
    daily = _csv(tmp / "Apple Music - Play History Daily Tracks.csv",
                 ["Track Description", "Date Played", "Play Count", "Skip Count"],
                 [["Fixture Band - Other Song", "20240302", "3", "0"]])
    activity = _csv(
        tmp / "Apple Music Play Activity.csv",
        ["Song Name", "Album Name", "Event Type", "Play Duration Milliseconds",
         "Event Timestamp", "Event End Timestamp", "Event Start Timestamp"],
        # Event Timestamp BLANK, Event End Timestamp set: the shape of two
        # thirds of the completed plays in a real export.
        [["Fixture Song", "Fixture Album", "PLAY_END", "200000",
          "", "2024-03-01T10:00:00Z", "2024-03-01T09:56:40Z"]])
    return _all_parsed(AppleParser(), [history, daily, activity])


def fixture_apple_music_library(tmp: Path) -> list:
    from services.ingest.src.parsers import apple_music_library as m
    export = tmp / m.EXPORT_FILE_NAME
    export.write_text(json.dumps({
        "source": m.EXPORT_SOURCE, "reader": "fixture",
        "tracks": [{"id": "1", "title": "Fixture Song", "artist": "Fixture Band",
                    "album": "Fixture Album", "genre": "Fixture Genre",
                    "play_count": 3, "last_played": "2024-03-01T10:00:00Z"}],
    }), encoding="utf-8")
    return _all_parsed(m.AppleMusicLibraryParser(), [export])


def fixture_spotify(tmp: Path) -> list:
    from services.ingest.src.parsers.spotify import SpotifyParser
    f = tmp / "StreamingHistory0.json"
    f.write_text(json.dumps([{"endTime": "2024-03-01 10:00", "artistName": "Fixture Band",
                              "trackName": "Fixture Song", "msPlayed": 200000}]),
                 encoding="utf-8")
    return _all_parsed(SpotifyParser(), [f])


def fixture_uber(tmp: Path) -> list:
    from services.ingest.src.parsers.uber import UberParser
    eats = _csv(tmp / "user_orders-0.csv",
                ["Restaurant_Name", "Item_Name", "City_Name", "Item_quantity", "Customizations",
                 "Order_Status", "Request_Time_Local", "Final_Delivery_Time_Local",
                 "Item_Price", "Order_Price", "Currency"],
                [["Fixture Noodle House", "Fixture Noodles", "Fixtureville", "1", "",
                  "COMPLETED", "2024-03-01 19:30:00", "2024-03-01 20:05:00", "9.5", "12", "USD"]])
    trips = _csv(tmp / "trips_data-0.csv",
                 ["status", "is_completed", "product_type_name", "global_product_name",
                  "city_name", "request_timestamp_local", "dropoff_timestamp_local",
                  "trip_distance_miles", "trip_duration_seconds", "fare_amount", "currency_code",
                  "begintrip_address", "dropoff_address", "destination_string"],
                 [["completed", "true", "UberX", "UberX", "Fixtureville",
                   "2024-03-02 08:00:00", "2024-03-02 08:20:00", "3.2", "1200", "11.5", "USD",
                   "1 Fixture Way", "2 Fixture Way", "Fixture Station"]])
    return _all_parsed(UberParser(), [eats, trips])


# ---------------------------------------------------------------------------
# The registry. Key = module name under services/ingest/src/parsers/.
# ---------------------------------------------------------------------------
OWN = "own_export"
INT_CL = "compartment_level is an int (ParsedPreference default 2)"
STABLE = "ParsedPreference.id = uuid5(source|source_id-or-subject|category|type)"
CAT = "parser sets category"


def _d(**kw):
    kw.setdefault("category", CAT)
    kw.setdefault("owner", OWN)
    kw.setdefault("privacy", INT_CL)
    kw.setdefault("item_key", STABLE)
    return Decl(**kw)


UNMEASURED = Gap("UNMEASURED: no points from this source on the measured box", None)

REGISTRY: Dict[str, Decl] = {
    "apple": _d(
        entity={"music": ("artist",)},
        timestamp=("music",),
        fixture=fixture_apple_music,
        gaps={
            "entity:ios_app": Gap("no seller/developer field on 1,419 app purchase points (ios_app, app)", None),
            "entity:podcast": Gap("podcast_name set on 49% of podcast points", None),
            "timestamp:personal_notes": Gap("observed_at set on 3% of note points", None),
            "timestamp:video": Gap("observed_at set on 39% of video points", None),
            "timestamp:fitness": Gap("observed_at absent on health/fitness patterns", None),
        },
    ),
    "apple_music_library": _d(
        entity={"music": ("artist",)}, timestamp=("music",),
        fixture=fixture_apple_music_library),
    "appletv": _d(entity={"movie": ("director",)}, timestamp=("movie", "tv_show")),
    "amazon": _d(
        entity={}, timestamp=("shopping",),
        gaps={
            "entity:shopping": Gap("only asin is kept; no brand or seller on 474 points", None),
            "entity:book": Gap("no author on book points (asin only)", None),
        }),
    "csv_parser": _d(
        entity={}, timestamp=(),
        category=Gap("category is keyword-guessed (category_inferred=true on 100% of 5,484 points)", None),
        gaps={"timestamp:*": Gap("rows carry no event time; observed_at absent on 100%", False)}),
    "discord": _d(entity={}, timestamp=(),
                  gaps={"timestamp:*": Gap("observed_at absent on 100% of 36 points", None)}),
    "disney": _d(entity={}, timestamp=(), gaps={"measure": UNMEASURED}),
    "ebay": _d(entity={}, timestamp=("product",),
               gaps={"entity:product": Gap("brand set on 25% of 3,627 points (parsed from the title)", None)}),
    "email": _d(entity={}, timestamp=(), owner=Gap("UNMEASURED: whose email statement it is", None),
                gaps={"measure": UNMEASURED}),
    "foursquare": _d(entity={"place": ("venue_id",)}, timestamp=("place",)),
    "google_takeout": _d(entity={}, timestamp=(), gaps={"measure": UNMEASURED}),
    "linkedin": _d(entity={}, timestamp=("professional",)),
    "meta": _d(entity={}, timestamp=("page", "saved")),
    "netflix": _d(entity={}, timestamp=("tv_show", "movie")),
    "pinterest": _d(entity={}, timestamp=(),
                    gaps={"timestamp:*": Gap("observed_at set on 16% of 781 points", None)}),
    "reddit": _d(entity={"social_media": ("subreddit",)}, timestamp=(),
                 gaps={"timestamp:*": Gap("votes, saved and subscriptions carry no date in the export", False)}),
    "spotify": _d(entity={"music": ("artist",)}, timestamp=("music",), fixture=fixture_spotify),
    "tiktok": _d(entity={}, timestamp=(), gaps={"measure": UNMEASURED}),
    "twitter": _d(entity={}, timestamp=(),
                  gaps={"timestamp:*": Gap("observed_at set on 34% of 3,589 points; likes carry no date", None)}),
    "uber": _d(entity={"food": ("restaurant",)}, timestamp=("food", "transportation"),
               fixture=fixture_uber),
    "whatsapp": _d(entity={}, timestamp=(),
                   owner=Gap("topics come from group chats; no owner-vs-other split on the point", None),
                   gaps={"timestamp:*": Gap("observed_at set on 10% of 83 points", None)}),
    "whoop": _d(entity={}, timestamp=("wellness",)),
    "youtube": _d(entity={}, timestamp=(), gaps={"measure": UNMEASURED}),
}

# Writers that are NOT parsers (they write the `preferences` collection
# directly, bypassing ParsedPreference) are checked by the test file's own
# fixtures: ostler_fda/pwg_ingest.py ingest_bookmarks and ingest_social.
