#!/usr/bin/env python3
"""The YouTube parser was claiming three Facebook files and destroying them.

MEASURED on a real customer box (v1.0.33 install log), three ERROR lines:

    Error parsing .../01 - Facebook/your_facebook_activity/comments_and_reactions/comments.json:
        'str' object has no attribute 'get'
    Error parsing .../your_facebook_activity/groups/group_posts_and_comments.json: same
    Error parsing .../your_facebook_activity/groups/your_comments_in_groups.json: same

and, one line apart from the first of them, the line that names the cause:

    Parsing YouTube comments from .../01 - Facebook/your_facebook_activity/groups/group_posts_and_comments.json

MECHANISM. ``YouTubeParser.can_parse`` claimed any ``*.json`` whose NAME
contains the substring "comments". All three Facebook filenames do.
``IngestPipeline._get_parser`` takes the FIRST parser that claims a file and
``YouTubeParser`` is registered ahead of ``MetaParser``, so Meta was never
asked. Meta's ``_looks_like_facebook_activity_json`` -- written specifically
so that "a YouTube export still falls through to the YouTube parser" -- could
therefore never run on these three files. A guard on the wrong side of the
queue is not a guard.

Then ``_parse_comments`` did ``for item in data`` on a top-level OBJECT,
which iterates its KEYS, and the first ``item.get`` raised on a str. The whole
file went on the floor.

WHAT THIS PINS
  1. YouTube declines all three real Facebook filenames when they hold
     Facebook content.
  2. Meta claims them.
  3. POSITIVE CONTROL: YouTube still claims a genuine Takeout comments.json.
     A guard that refuses everything would pass limb 1 and be worthless.
  4. The routing that actually decides, using the two parsers in the order
     read out of the SHIPPED pipeline.py rather than an order restated here.
  5. The residual: handed a Facebook payload anyway, the comments limb warns
     and yields nothing instead of raising.

BOUND, stated rather than implied: limb 4 simulates the dispatcher over the
TWO parsers that contend for these names. A third parser claiming them would
not be seen by this test.

Every fixture is SYNTHETIC. No customer data, no real names. See
PRODUCTISATION_CHECKLIST.md Rule zero.

Exit: 0 all pass, 1 a real failure, 2 cannot-run (never a silent pass).
"""

import asyncio
import json
import re
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
INGEST = REPO / "vendor" / "cm019_preferences" / "services" / "ingest"
PIPELINE_PY = INGEST / "src" / "pipeline.py"

PASS = 0
FAIL = 0


def ok(msg: str) -> None:
    global PASS
    print(f"  PASS  {msg}")
    PASS += 1


def no(msg: str) -> None:
    global FAIL
    print(f"  FAIL  {msg}")
    FAIL += 1


def cannot_run(msg: str) -> None:
    print(f"CANNOT RUN: {msg}", file=sys.stderr)
    sys.exit(2)


if not INGEST.is_dir():
    cannot_run(f"vendored ingest service missing at {INGEST}")
sys.path.insert(0, str(INGEST))

try:
    from src.parsers.youtube import YouTubeParser
    from src.parsers.meta import MetaParser
except Exception as exc:  # noqa: BLE001
    cannot_run(f"could not import the shipped parsers: {type(exc).__name__}: {exc}")


# ---------------------------------------------------------------------------
# Synthetic fixtures. Facebook activity exports are a top-level object keyed
# by "*_v2"; Google Takeout exports are a top-level array.
# ---------------------------------------------------------------------------

FACEBOOK_FILES = {
    "comments.json": {
        "comments_v2": [
            {"timestamp": 1600000000,
             "data": [{"comment": {"comment": "synthetic comment text"}}]}
        ]
    },
    "group_posts_and_comments.json": {
        "group_posts_v2": [
            {"timestamp": 1600000001, "title": "Synthetic Group Post"}
        ]
    },
    "your_comments_in_groups.json": {
        "group_comments_v2": [
            {"timestamp": 1600000002,
             "data": [{"comment": {"comment": "synthetic group comment"}}]}
        ]
    },
}

YOUTUBE_COMMENTS = [
    {"snippet": {"videoId": "synthetic_video_1"}},
    {"snippet": {"videoId": "synthetic_video_2"}},
]

YOUTUBE_OTHER_FILES = {
    "watch-history.json": [
        {"header": "YouTube", "title": "Watched Synthetic Clip",
         "titleUrl": "https://example.invalid/watch?v=synthetic",
         "time": "2026-01-01T00:00:00Z"}
    ],
    "subscriptions.json": [
        {"snippet": {"title": "Synthetic Channel",
                     "resourceId": {"channelId": "synthetic_channel"}}}
    ],
}


def write(root: Path, rel: str, payload: object) -> Path:
    path = root / rel
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def shipped_relative_order() -> list:
    """Read the parser registration order out of the SHIPPED pipeline.py.

    Restating the order here would make this limb agree with itself. It is
    extracted so that a reorder in the product changes what this test
    measures.
    """
    if not PIPELINE_PY.is_file():
        cannot_run(f"pipeline.py missing at {PIPELINE_PY}")
    src = PIPELINE_PY.read_text(encoding="utf-8")
    block = re.search(r"self\.parsers:\s*List\[BaseParser\]\s*=\s*\[(.*?)\n\s*\]",
                      src, re.S)
    if not block:
        cannot_run("could not find the parser registration list in pipeline.py; "
                   "a routing verdict from an unread list would be meaningless")
    names = re.findall(r"^\s*(\w+)\(\)", block.group(1), re.M)
    if len(names) < 10:
        cannot_run(f"extracted only {len(names)} parsers from the registration "
                   "list; the extractor is not matching")
    for wanted in ("YouTubeParser", "MetaParser"):
        if wanted not in names:
            cannot_run(f"{wanted} is not registered in pipeline.py")
    print(f"  ..    registration list read: {len(names)} parsers, "
          f"YouTubeParser at {names.index('YouTubeParser')}, "
          f"MetaParser at {names.index('MetaParser')}")
    pair = [n for n in names if n in ("YouTubeParser", "MetaParser")]
    return [{"YouTubeParser": YouTubeParser, "MetaParser": MetaParser}[n]()
            for n in pair]


def first_claimer(parsers: list, path: Path):
    for parser in parsers:
        if parser.can_parse(path):
            return parser
    return None


def main() -> int:
    yt = YouTubeParser()
    meta = MetaParser()
    ordered = shipped_relative_order()

    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # -- 1 + 2: the three files that were destroyed on the box ----------
        fb_paths = []
        for name, payload in FACEBOOK_FILES.items():
            sub = "comments_and_reactions" if name == "comments.json" else "groups"
            fb_paths.append(write(root, f"01 - Facebook/your_facebook_activity/{sub}/{name}",
                                  payload))

        for path in fb_paths:
            if yt.can_parse(path):
                no(f"YouTube still claims {path.name}")
            else:
                ok(f"YouTube declines {path.name}")

        for path in fb_paths:
            if meta.can_parse(path):
                ok(f"Meta claims {path.name}")
            else:
                no(f"Meta does NOT claim {path.name}; nothing would parse it")

        # -- 3: POSITIVE CONTROL -------------------------------------------
        yt_comments = write(root, "Takeout/YouTube and YouTube Music/comments.json",
                            YOUTUBE_COMMENTS)
        if yt.can_parse(yt_comments):
            ok("YouTube still claims a genuine Takeout comments.json")
        else:
            no("YouTube no longer claims its OWN comments.json; the guard is "
               "refusing everything, which passes the Facebook limbs for the "
               "wrong reason")

        if meta.can_parse(yt_comments):
            no("Meta claims a YouTube comments.json")
        else:
            ok("Meta still declines a YouTube comments.json")

        for name, payload in YOUTUBE_OTHER_FILES.items():
            path = write(root, f"Takeout/YouTube and YouTube Music/{name}", payload)
            if yt.can_parse(path):
                ok(f"YouTube still claims {name}")
            else:
                no(f"YouTube stopped claiming {name}; the change narrowed the parser")

        # -- 4: the routing that actually decides ---------------------------
        for path in fb_paths:
            winner = first_claimer(ordered, path)
            got = type(winner).__name__ if winner else "nobody"
            if got == "MetaParser":
                ok(f"routing: {path.name} -> MetaParser")
            else:
                no(f"routing: {path.name} -> {got}, expected MetaParser")

        winner = first_claimer(ordered, yt_comments)
        got = type(winner).__name__ if winner else "nobody"
        if got == "YouTubeParser":
            ok("routing: a genuine Takeout comments.json -> YouTubeParser")
        else:
            no(f"routing: Takeout comments.json -> {got}, expected YouTubeParser")

        # -- 5: the residual, if a Facebook payload reaches the limb anyway --
        misnamed = write(root, "comments.json", FACEBOOK_FILES["comments.json"])

        async def drain():
            out = []
            async for pref in yt._parse_comments(misnamed, 4):
                out.append(pref)
            return out

        try:
            produced = asyncio.run(drain())
        except AttributeError as exc:
            no(f"the comments limb still raises on a Facebook payload: {exc}")
        except Exception as exc:  # noqa: BLE001
            no(f"the comments limb raised {type(exc).__name__} on a Facebook "
               f"payload: {exc}")
        else:
            ok("the comments limb handed a Facebook payload warns instead of raising")
            if produced:
                no(f"it also produced {len(produced)} preferences from a "
                   "Facebook payload")

    print()
    print(f"  {PASS} passed, {FAIL} failed")
    if FAIL:
        return 1
    print("YOUTUBE/FACEBOOK CLAIM SEPARATION HOLDS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
