"""Tracking parameters are stripped from browsing URLs at every ingest point.

Synthetic URLs only (example.com family, public video/search hosts as
negative controls, no real person's data). Drives the SHIPPED readers
(safari_history, chrome_history, safari_bookmarks) and the SHIPPED sink
(pwg_ingest.ingest_browser_history) with only the network edge faked.

Red on origin/main: the readers and the sink store the URL as read.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
import sys
import time
import uuid
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
VENDOR = REPO / "vendor"
if str(VENDOR) not in sys.path:
    sys.path.insert(0, str(VENDOR))

COPIES = [VENDOR / "ostler_fda" / "url_clean.py",
          VENDOR / "cm041" / "assistant_api" / "url_clean.py"]
# Same constant as HR015 ostler_fda/tests/test_url_clean.py.
URL_CLEAN_SHA256 = "a8ddf79be1fbf9e9473209c41223a011bfd904610a642cc0be2fbf7abf3f9c30"

# (input, expected). Rows marked CONTROL must come out byte-identical.
TABLE = [
    # tracking params removed
    ("https://example.com/a?utm_source=n&utm_medium=e&id=7", "https://example.com/a?id=7"),
    ("https://example.com/a?UTM_Campaign=x", "https://example.com/a"),
    ("https://example.com/?fbclid=AbC123", "https://example.com/"),
    ("https://example.com/p?x=1&gclid=Z&y=2", "https://example.com/p?x=1&y=2"),
    ("https://example.com/p?gbraid=a&wbraid=b&dclid=c&msclkid=d&k=v", "https://example.com/p?k=v"),
    ("https://example.com/p?mc_cid=a&mc_eid=b&igshid=c&k=v", "https://example.com/p?k=v"),
    ("https://example.com/p?_hsenc=a&_hsmi=b&mkt_tok=c&k=v", "https://example.com/p?k=v"),
    ("https://example.com/p?yclid=a&twclid=b&ttclid=c&li_fat_id=d&k=v", "https://example.com/p?k=v"),
    ("https://example.com/p?oly_anon_id=a&oly_enc_id=b&vero_id=c&_ga=d&_gl=e&ref_src=f&k=v",
     "https://example.com/p?k=v"),
    ("https://example.com/p?k=v&fbclid=1#top", "https://example.com/p?k=v#top"),
    # host-scoped
    ("https://open.spotify.com/track/abc?si=zzz", "https://open.spotify.com/track/abc"),
    ("https://youtu.be/dQw4w9WgXcQ?si=zzz&t=42", "https://youtu.be/dQw4w9WgXcQ?t=42"),
    ("https://www.aliexpress.com/item/1.html?spm=a2g0o.x&sku=3", "https://www.aliexpress.com/item/1.html?sku=3"),
    # text fragments
    ("https://example.com/a#:~:text=hello%20world", "https://example.com/a"),
    ("https://example.com/a#sec:~:text=hello", "https://example.com/a#sec"),
    ("https://example.com/a?utm_source=n#:~:text=x", "https://example.com/a"),
    # CONTROLS: functional params survive
    ("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
    ("https://www.youtube.com/watch?v=abc&list=PL1&t=30s", "https://www.youtube.com/watch?v=abc&list=PL1&t=30s"),
    ("https://www.youtube.com/watch?v=abc&si=keep", "https://www.youtube.com/watch?v=abc&si=keep"),
    ("https://www.google.com/search?q=example+query&hl=en", "https://www.google.com/search?q=example+query&hl=en"),
    ("https://example.com/p?si=keep", "https://example.com/p?si=keep"),
    ("https://example.com/p?spm=keep", "https://example.com/p?spm=keep"),
    ("https://example.com/p?ref=keep&page=2&id=9", "https://example.com/p?ref=keep&page=2&id=9"),
    ("https://example.com/p?utmost=keep", "https://example.com/p?utmost=keep"),
    ("https://example.com/a#section-2", "https://example.com/a#section-2"),
    # byte-identical oddities
    ("https://example.com/a?", "https://example.com/a?"),
    ("https://example.com/a?b", "https://example.com/a?b"),
    ("https://example.com/a?b=%zz&&c=1", "https://example.com/a?b=%zz&&c=1"),
    ("https://Example.COM:8443/A%20B?Q=1#F", "https://Example.COM:8443/A%20B?Q=1#F"),
    ("file:///tmp/x?utm_source=a", "file:///tmp/x?utm_source=a"),
    ("", ""),
]


def check_table(fn):
    """Return the rows `fn` gets wrong (empty list = all correct)."""
    return [(i, o, fn(i)) for i, o in TABLE if fn(i) != o]


def test_table():
    from ostler_fda.url_clean import strip_tracking
    bad = check_table(strip_tracking)
    assert not bad, bad


def test_idempotent_and_total_rows():
    from ostler_fda.url_clean import strip_tracking
    assert len(TABLE) >= 30
    for _, out in TABLE:
        assert strip_tracking(out) == out


def test_non_string_unchanged():
    from ostler_fda.url_clean import strip_tracking
    assert strip_tracking(None) is None
    assert strip_tracking(5) == 5


def test_mutants_are_caught():
    """Break the strip function four ways; the table must go red each time."""
    from urllib.parse import urlsplit, urlunsplit
    from ostler_fda import url_clean as uc

    def identity(u):
        return u

    def drop_all_params(u):
        s = urlsplit(u)
        return urlunsplit((s.scheme, s.netloc, s.path, "", s.fragment))

    def drop_q_too(u):
        out = uc.strip_tracking(u)
        return out.replace("q=example+query&", "")

    def host_blind(u):
        # strips si/spm everywhere
        import re
        out = uc.strip_tracking(u)
        return re.sub(r"([?&])(si|spm)=[^&#]*&?", r"\1", out).rstrip("?&")

    assert check_table(uc.strip_tracking) == []
    for name, mut in (("identity", identity), ("drop_all_params", drop_all_params),
                      ("drop_q_too", drop_q_too), ("host_blind", host_blind)):
        assert check_table(mut), f"mutant {name} was not caught"


def test_copies_are_byte_identical():
    digests = {p.relative_to(REPO).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
               for p in COPIES}
    assert set(digests.values()) == {URL_CLEAN_SHA256}, digests


# ---- the readers -------------------------------------------------------

MAC_EPOCH = 978307200
CHROME_EPOCH = 11644473600
TRACKED = "https://www.example.com/story?utm_source=nl&fbclid=ABC&id=42"
CLEAN = "https://www.example.com/story?id=42"
YT = "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL1&t=30s"
GS = "https://www.google.com/search?q=example+query"


def _safari_db(path):
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, visit_count INTEGER);"
        "CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER,"
        " visit_time REAL, title TEXT, redirect_source INTEGER);")
    now = time.time() - 3600 - MAC_EPOCH
    for i, u in enumerate((TRACKED, YT, GS)):
        con.execute("INSERT INTO history_items VALUES (?,?,1)", (i, u))
        con.execute("INSERT INTO history_visits VALUES (?,?,?,?,NULL)", (i, i, now, f"T{i}"))
    con.commit()
    con.close()


def _chrome_db(path):
    con = sqlite3.connect(path)
    con.executescript(
        "CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER,"
        " last_visit_time INTEGER);"
        "CREATE TABLE visits (id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER,"
        " from_visit INTEGER);")
    t = int((time.time() - 3600 + CHROME_EPOCH) * 1_000_000)
    for i, u in enumerate((TRACKED, YT, GS)):
        con.execute("INSERT INTO urls VALUES (?,?,?,1,0)", (i, u, f"T{i}"))
        con.execute("INSERT INTO visits VALUES (?,?,?,0)", (i, i, t))
    con.commit()
    con.close()


def test_safari_reader(tmp_path):
    from ostler_fda import safari_history
    db = tmp_path / "History.db"
    _safari_db(db)
    urls = {e.url for e in safari_history.extract_history(db, since_days=30)}
    assert urls == {CLEAN, YT, GS}, urls


def test_chrome_reader(tmp_path):
    from ostler_fda import chrome_history
    db = tmp_path / "History"
    _chrome_db(db)
    urls = {e.url for e in chrome_history.extract_history(db, since_days=30)}
    assert urls == {CLEAN, YT, GS}, urls


def test_bookmarks(tmp_path):
    import plistlib
    from ostler_fda import safari_bookmarks
    leaf = lambda u: {"WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": u,
                      "URIDictionary": {"title": "t"}}
    tree = {"WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar",
            "Children": [leaf(TRACKED), leaf(YT)]}
    got = {b.url for b in safari_bookmarks._walk_bookmarks(tree)}
    assert got == {CLEAN, YT}, got


# ---- the sink: dedupe key is the cleaned url ---------------------------

class Sink:
    def __init__(self):
        self.points = {}

    def upsert(self, collection, points):
        for p in points:
            if p.get("vector"):
                self.points[p["id"]] = p["payload"]
        return len([p for p in points if p.get("vector")])


@pytest.fixture()
def sink(monkeypatch, tmp_path):
    monkeypatch.setenv("OSTLER_HOME", str(tmp_path / "home"))
    from ostler_fda import pwg_ingest
    s = Sink()
    monkeypatch.setattr(pwg_ingest, "_ollama_embed_batch", lambda texts: [[0.1, 0.2, 0.3] for _ in texts])
    monkeypatch.setattr(pwg_ingest, "_qdrant_ensure_collection", lambda *a, **k: None)
    monkeypatch.setattr(pwg_ingest, "_qdrant_upsert_points", s.upsert)
    return pwg_ingest, s


def _visit(url, ts="2026-10-01T10:00:00+00:00", source="safari_history"):
    return {"type": "web_visit", "timestamp": ts, "url": url, "domain": "www.example.com",
            "title": "t", "visit_count": 1, "source": source}


def test_sink_strips_and_dedupes(sink, tmp_path):
    pwg, s = sink
    fda = tmp_path / "fda"
    fda.mkdir()
    # an OLD extractor file: tracked and clean forms of the same visit,
    # plus two functional controls.
    (fda / "safari_history.json").write_text(json.dumps([
        _visit(TRACKED), _visit(CLEAN), _visit(YT), _visit(GS)]))
    res = pwg.ingest_browser_history(fda)
    stored = sorted(p["url"] for p in s.points.values())
    assert stored == sorted([CLEAN, YT, GS]), stored
    assert all("utm_" not in u and "fbclid" not in u for u in stored)
    want_id = str(uuid.uuid5(uuid.NAMESPACE_URL,
                             f"browsing|safari_history|{CLEAN}|2026-10-01T10:00:00+00:00"))
    assert want_id in s.points
    assert res["sent"] >= 3
